# SQS Integration for Seqera Platform

This guide covers setting up and testing SQS integration with Nextflow workflows running on Seqera Platform.

## Overview

When running Nextflow workflows on Seqera Platform, you can send completion notifications to a Quilt catalog PackagerQueue via SQS. This requires:

1. AWS CLI and credentials available in the compute environment
2. IAM role with `sqs:SendMessage` permission for the target queue
3. Workflow code with `workflow.onComplete` block to send the SQS message

## Quick Start

### 1. Automated Setup

Use the setup script to configure IAM permissions:

```bash
# Interactive mode
./setup-sqs.py

# With AWS profile
./setup-sqs.py --profile sales

# Non-interactive mode
./setup-sqs.py --profile sales --yes
```

The script will:

- Discover your Quilt catalog configuration
- Find the PackagerQueue in CloudFormation
- Update TowerForge IAM roles with SQS permissions
- Save configuration to `config.toml`

### 2. Verify Setup

```bash
./check-sqs.sh --profile sales
```

### 3. Test Integration

```bash
./test-sqs.sh --yes
```

## Architecture

The post-run script architecture has two components:

1. **Bash launcher** ([scripts/post-run-sqs.sh](scripts/post-run-sqs.sh)) - Downloads and executes Python script
2. **Python integration** ([scripts/post_run_sqs.py](scripts/post_run_sqs.py)) - Fetches workflow metadata from Seqera Platform API, parses WRROC metadata, and sends to SQS

```text
┌─────────────────────────────────────────┐
│ Seqera Platform Compute Environment     │
│                                         │
│  TowerForge IAM Role                    │
│   - batch:*, ecs:*                      │
│   - sqs:SendMessage ← (added by setup)  │
└────────────────┬────────────────────────┘
                 │ SQS Message
                 ↓
┌─────────────────────────────────────────┐
│ AWS SQS → Quilt Catalog Lambda          │
└─────────────────────────────────────────┘
```

## Configuration

### Required Parameters

When launching workflows, specify:

```bash
--params.sqs_queue_url 'https://sqs.us-east-1.amazonaws.com/ACCOUNT/QUEUE-NAME'
```

### Post-Run Hook

Configure in Seqera Platform:

```bash
curl -sSfL https://raw.githubusercontent.com/data-yaml/seqera-smoke-test/parse-wrroc/scripts/post-run-sqs.sh | bash
```

## Metadata Sent to SQS

The script sends comprehensive metadata including:

- **Seqera Platform API**: params, run name, status, session ID, launch info, compute env, duration
- **TOWER_* Environment Variables**: workflow ID, project/workspace IDs, user ID, timeline, pipeline info
- **WRROC Metadata**: name, dates, license, author, runtime platform, programming language

## Troubleshooting

**Permission Denied:**

1. Find compute environment's role: `tw compute-envs view --name=<env>`
2. Verify role has permission: `aws iam get-role-policy --role-name TowerForge-XXX-FargateRole --policy-name nextflow-policy`
3. Re-run setup: `./setup-sqs.py --profile sales --yes`

**AWS CLI Not Found:**

- Compute environment container must have AWS CLI installed
- Seqera Platform Forge environments use `ubuntu:22.04` which includes AWS CLI

**Region Mismatch:**

- Ensure workflow uses same region as PackagerQueue

## Files

- `setup-sqs.py` - Automated IAM setup (generates config.toml)
- `check-sqs.sh` - Verification script
- `test-sqs.sh` - End-to-end test
- `scripts/post-run-sqs.sh` - Post-run hook launcher
- `scripts/post_run_sqs.py` - Main integration logic
- `config.toml` - Generated configuration

## Related Documentation

- [Seqera Platform Compute Environments](https://docs.seqera.io/platform/latest/compute-envs/overview)
- [AWS SQS SendMessage API](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_SendMessage.html)
- [Nextflow workflow.onComplete](https://www.nextflow.io/docs/latest/metadata.html#workflow-oncomplete)
