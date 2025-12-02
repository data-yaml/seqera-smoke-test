# SQS Integration Setup for Seqera Platform

This directory contains tools for setting up SQS integration between Nextflow workflows running on Seqera Platform and Quilt catalog PackagerQueues.

## Overview

When running Nextflow workflows on Seqera Platform (formerly Tower), you may want to send notifications to a Quilt PackagerQueue when workflows complete. This requires:

1. The Nextflow workflow to have AWS CLI and credentials available
2. The compute environment's IAM role to have `sqs:SendMessage` permission for the target queue
3. The workflow code to send the SQS message in the `workflow.onComplete` block

## Quick Start

### Automated Setup

Use the `setup-sqs.py` script to automatically discover your Quilt catalog configuration and update TowerForge IAM roles:

```bash
# Interactive mode - will prompt for inputs
./setup-sqs.py

# With AWS profile
./setup-sqs.py --profile sales

# With explicit catalog URL
./setup-sqs.py --catalog https://demo.quiltdata.com

# Non-interactive mode (requires catalog or quilt3 CLI configured)
./setup-sqs.py --profile sales --yes
```

### What the Script Does

1. **Discovers Catalog Configuration**
   - Checks `quilt3 config` for catalog URL (or prompts you)
   - Fetches catalog's `/config.json` to get AWS region

2. **Finds CloudFormation Stack**
   - Searches for Quilt stack in the region
   - Matches stack by `QuiltWebHost` output
   - Extracts `PackagerQueue` URL and ARN

3. **Finds TowerForge Roles**
   - Lists IAM roles in the account
   - Filters for TowerForge roles (Fargate or EC2 Instance roles used by compute environments)

4. **Updates Permissions**
   - Checks if roles already have `sqs:SendMessage` permission
   - Adds permission to `nextflow-policy` inline policy if missing
   - Displays summary of all changes

5. **Writes Configuration**
   - Saves queue URL, ARN, and stack info to `config.toml`
   - Used by `check-sqs.sh` to verify the setup

### Verify Setup

After running setup, verify the configuration:

```bash
# Check configuration and verify AWS access
./check-sqs.sh

# With specific AWS profile
./check-sqs.sh --profile sales

# Show detailed information
./check-sqs.sh --profile sales --verbose
```

The verification script will:

1. Read the configuration from `config.toml`
2. Verify SQS queue is accessible
3. Check CloudFormation stack exists
4. Verify IAM role permissions
5. Send a test message to confirm write access

## Manual Testing

After setup, test the SQS integration with:

```bash
# Run smoke test
./test-sqs.sh --yes
```

This will:

1. Launch a simple Nextflow workflow via Seqera Platform
2. Wait for completion
3. Verify an SQS message was sent to the PackagerQueue

## Workflow Implementation

The test workflow [main-sqs.nf](main-sqs.nf) demonstrates how to implement SQS integration:

```groovy
workflow.onComplete {
    String queueUrl = 'https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA'
    String region = 'us-east-1'
    String outdir = params.outdir

    // Check AWS CLI availability
    def awsCheck = ['aws', '--version'].execute()
    awsCheck.waitFor()
    if (awsCheck.exitValue() != 0) {
        throw new Exception("AWS CLI not available")
    }

    // Check AWS credentials
    def credsCheck = ['aws', 'sts', 'get-caller-identity'].execute()
    credsCheck.waitFor()
    if (credsCheck.exitValue() != 0) {
        throw new Exception("AWS credentials not configured")
    }

    // Send SQS message
    def cmd = [
        'aws', 'sqs', 'send-message',
        '--queue-url', queueUrl,
        '--region', region,
        '--message-body', outdir
    ]
    def p = cmd.execute()
    p.waitFor()

    if (p.exitValue() != 0) {
        String errorText = p.err.text
        throw new Exception("SQS message send failed: ${errorText}")
    }
}
```

### Key Requirements

1. **AWS CLI in Container**: The compute environment must have AWS CLI installed
2. **AWS Credentials**: The task must have AWS credentials (via IAM role or environment variables)
3. **IAM Permission**: The role must have `sqs:SendMessage` for the target queue
4. **Error Handling**: Check exit codes and fail the workflow if SQS send fails

## Troubleshooting

### Permission Denied

If you see `AccessDenied` errors when running the workflow:

1. Check that the correct role was updated:

   ```bash
   # Find the role used by your compute environment
   tw compute-envs view --name=<compute-env> --workspace=<workspace>
   # Look for "headJobRole" in the output
   ```

2. Verify the role has the permission:

   ```bash
   # For Fargate compute environments
   AWS_PROFILE=sales aws iam get-role-policy \
     --role-name TowerForge-XXX-FargateRole \
     --policy-name nextflow-policy | grep -A 5 SQS

   # For EC2 compute environments
   AWS_PROFILE=sales aws iam get-role-policy \
     --role-name TowerForge-XXX-InstanceRole \
     --policy-name nextflow-policy | grep -A 5 SQS
   ```

3. Re-run setup script to add permission:

   ```bash
   ./setup-sqs.py --profile sales --catalog https://demo.quiltdata.com --yes
   ```

### AWS CLI Not Found

If workflow fails with "AWS CLI not available":

- The compute environment's container image must have AWS CLI installed
- Seqera Platform Forge environments typically use `ubuntu:22.04` which has AWS CLI
- For custom containers, add AWS CLI installation to your Dockerfile

### Region Mismatch

The workflow must use the same region as the PackagerQueue:

```groovy
// Bad - wrong region
String region = 'us-west-2'  // Queue is in us-east-1

// Good - matches queue region
String region = 'us-east-1'
```

## Files

- `setup-sqs.py` - Automated setup script for SQS permissions (generates config.toml)
- `check-sqs.sh` - Verification script that reads config.toml and validates setup
- `test-sqs.sh` - Test script that launches workflow and verifies SQS integration
- `main-sqs.nf` - Example Nextflow workflow with SQS integration
- `config.toml` - Generated configuration file (created by setup-sqs.py)
- `config.toml.example` - Example configuration file with placeholder values
- `lib/tw-common.sh` - Common functions for Seqera Platform CLI operations

## Architecture

```text
┌─────────────────────────────────────────┐
│ Seqera Platform                         │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │ Compute Environment (AWS Batch)   │  │
│  │                                   │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │ Nextflow Head Job           │  │  │
│  │  │ (Fargate or EC2)            │  │  │
│  │  │                             │  │  │
│  │  │ Role: TowerForge-XXX-       │  │  │
│  │  │       FargateRole or        │  │  │
│  │  │       InstanceRole          │  │  │
│  │  │                             │  │  │
│  │  │ Permissions:                │  │  │
│  │  │  - batch:*                  │  │  │
│  │  │  - ecs:*                    │  │  │
│  │  │  - sqs:SendMessage ←────────┼──┼──┼─── Added by setup-sqs.py
│  │  │                             │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
                    │
                    │ SQS Message
                    ↓
┌─────────────────────────────────────────┐
│ AWS SQS (us-east-1)                     │
│                                         │
│  PackagerQueue-XXX                      │
│  arn:aws:sqs:us-east-1:ACCOUNT:QUEUE    │
└─────────────────────────────────────────┘
                    │
                    ↓
┌─────────────────────────────────────────┐
│ Quilt Catalog Lambda                    │
│                                         │
│  Processes SQS messages and updates     │
│  catalog metadata                       │
└─────────────────────────────────────────┘
```

## Related Documentation

- [Seqera Platform Compute Environments](https://docs.seqera.io/platform/latest/compute-envs/overview)
- [AWS SQS SendMessage API](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_SendMessage.html)
- [Nextflow workflow.onComplete](https://www.nextflow.io/docs/latest/metadata.html#workflow-oncomplete)
