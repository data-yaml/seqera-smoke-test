# Seqera Platform Smoke Test

A simple, self-contained test suite for validating Seqera Platform deployments.

## Overview

This repository contains a minimal Nextflow workflow designed to:

- Verify Seqera Platform connectivity
- Test AWS Batch job execution
- Validate S3 output publishing
- Confirm SQS message delivery (optional)

## QuickStart

If everything is setup:

```bash
./test-local.sh
./test-tw.sh  # prompts for S3 output bucket
```

Else see below.

## Prerequisites

### Required Tools

1. **Nextflow** - Workflow orchestration engine
   - Installation: <https://www.nextflow.io/docs/latest/install.html>
   - Quick install: `curl -s https://get.nextflow.io | bash`
   - macOS: brew install nextflow
   - Verify: `nextflow -version`

2. **Seqera Platform CLI (tw)** - Command-line interface for Seqera Platform
   - Installation: <https://docs.seqera.io/platform/latest/cli/cli>
   - Quick install:

     ```bash
     # Linux
     curl -fsSL https://github.com/seqeralabs/tower-cli/releases/latest/download/tw-linux-x86_64 -o tw
     chmod +x tw
     sudo mv tw /usr/local/bin/
     ```

   - Configure: `tw login`
   - Verify: `tw info`

3. **AWS CLI** (optional, for SQS notifications)
   - Installation: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
   - Configure: `aws configure`
   - Verify: `aws sts get-caller-identity`

### Access Requirements

- Seqera Platform workspace with appropriate permissions
- AWS Batch compute environment configured in Seqera Platform
- S3 bucket for workflow outputs (if running on AWS)

## Usage

### 1. Local Test (No Seqera Platform)

Test the workflow locally before deploying:

```bash
nextflow run main.nf --outdir results
```

Expected output:

- `results/test.txt` containing "Hello from tiny test"
- Workflow completes successfully

### 2. Run on Seqera Platform

#### Option A: Using Seqera CLI

```bash
tw launch https://github.com/data-yaml/seqera-smoke-test \
  --profile smoke \
  --config seqera.config \
  --outdir s3://your-bucket/smoke-test-results
```

#### Option B: Via Seqera Platform UI

1. Navigate to Launchpad
2. Add new pipeline
3. Pipeline URL: `https://github.com/data-yaml/seqera-smoke-test`
4. Config profiles: `smoke`
5. Parameters:
   - `outdir`: `s3://your-bucket/smoke-test-results`

### 3. Verify Results

Check that:

1. Workflow completes with exit status 0
2. Output file exists at `s3://your-bucket/smoke-test-results/test.txt`
3. SQS message sent (if configured)

## Configuration

### Workflow Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `outdir` | `results` | Output directory (local or S3 path) |

### Profile: `smoke`

Configured in [seqera.config](seqera.config):

- Executor: AWS Batch
- CPU: 1
- Memory: 512 MB
- Time limit: 5 minutes
- Region: us-east-1

### SQS Integration

The workflow sends a completion message to SQS (configured in [nextflow.config](nextflow.config)).

**Current configuration:**

- Queue URL: `https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA`
- Message body: Output directory path

To disable or modify:

1. Edit [nextflow.config](nextflow.config)
2. Update `queueUrl` or comment out the `workflow.onComplete` block

## Files

- [main.nf](main.nf) - Main workflow definition
- [nextflow.config](nextflow.config) - Workflow configuration and SQS integration
- [seqera.config](seqera.config) - Seqera Platform profile configuration
- [test-local.sh](test-local.sh) - Local test runner script

## Troubleshooting

### Common Issues

**Workflow fails immediately:**

- Check AWS credentials: `aws sts get-caller-identity`
- Verify Seqera Platform connection: `tw info`

**Process hangs on AWS Batch:**

- Check compute environment status in AWS Batch console
- Verify IAM permissions for Batch execution role
- Check VPC/subnet configuration

**S3 output not found:**

- Verify bucket exists and permissions are correct
- Check Batch execution role has S3 write permissions
- Review CloudWatch logs for the Batch job

**SQS message not delivered:**

- Verify queue URL is correct
- Check IAM permissions for SQS SendMessage
- Review workflow completion logs

### Debug Commands

```bash
# Check Nextflow version
nextflow -version

# Validate workflow syntax
nextflow run main.nf --help

# Run with verbose logging
nextflow run main.nf -with-trace -with-report -with-timeline

# Check AWS configuration
aws sts get-caller-identity
aws s3 ls s3://your-bucket/

# Check Seqera Platform status
tw info
tw workspaces list
tw compute-envs list
```

## Testing Checklist

- [ ] Workflow runs successfully locally
- [ ] Workflow submits to Seqera Platform
- [ ] Process executes on AWS Batch
- [ ] Output published to S3
- [ ] SQS message delivered (if configured)
- [ ] Workflow marked as completed in Seqera Platform UI

## Customization

### Add More Tests

Edit [main.nf](main.nf) to add additional processes:

```groovy
process test_computation {
    publishDir params.outdir, mode: 'copy'

    output:
    path "computation.txt"

    script:
    """
    echo "Testing CPU: \${HOSTNAME}" > computation.txt
    date >> computation.txt
    df -h >> computation.txt
    """
}
```

### Change AWS Region

Edit [seqera.config](seqera.config):

```groovy
aws.region = 'us-west-2'
```

### Adjust Resources

Edit [seqera.config](seqera.config):

```groovy
process.cpus   = 2
process.memory = '1 GB'
process.time   = '10 min'
```

## License

See [LICENSE](LICENSE) file.
