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
./test-local.sh           # Test locally with Docker
./test-tw.sh              # Interactive mode - prompts for configuration
./test-tw.sh --yes        # Automated mode - uses saved configuration
./test-sqs.sh             # Interactive mode WITH SQS integration
./test-sqs.sh --yes       # Automated mode WITH SQS integration
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
   - Repository: <https://github.com/seqeralabs/tower-cli>
   - Documentation: <https://docs.seqera.io/platform/latest/cli/cli>
   - Quick install:

     ```bash
     # Homebrew (macOS/Linux)
     brew install seqeralabs/tap/tw

     # Or download directly from releases
     # https://github.com/seqeralabs/tower-cli/releases/latest
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

#### Option A: Using the Test Script (Recommended)

**Interactive Mode:**

```bash
./test-tw.sh
```

On first run, the script will prompt you for:

- Seqera Platform workspace
- Compute environment
- S3 output bucket

These values are saved to `.env` and `work/params.yaml` for future runs.

**Automated Mode (for CI/CD):**

```bash
./test-tw.sh --yes
```

Skips all prompts and uses saved configuration. Requires:

- `TOWER_WORKSPACE_ID` in `.env`
- `work/params.yaml` with S3 bucket configured

Run without `--yes` first to set up these configurations.

### 3. Run with SQS Integration

For SQS integration setup and testing, see [README-SQS.md](README-SQS.md).

Quick test:

```bash
./test-sqs.sh --yes
```

### 4. Alternative Launch Methods

#### Option A: Using Seqera CLI Directly

Create a params file (e.g., `params.yaml`):

```yaml
outdir: s3://your-bucket/smoke-test-results
```

Then launch:

```bash
tw launch https://github.com/data-yaml/seqera-smoke-test \
  --workspace="Organization/Workspace" \
  --compute-env="your-compute-env" \
  --profile awsbatch \
  --params-file params.yaml
```

#### Option C: Via Seqera Platform UI

1. Navigate to Launchpad
2. Add new pipeline
3. Pipeline URL: `https://github.com/data-yaml/seqera-smoke-test`
4. Config profiles: `awsbatch`
5. Parameters:
   - `outdir`: `s3://your-bucket/smoke-test-results`

### 5. Verify Results

Check that:

1. Workflow completes with exit status 0
2. Output file exists at `s3://your-bucket/smoke-test-results/test.txt`
3. SQS message sent (if configured)

## Configuration

### Workflow Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `outdir` | `results` | Output directory (local or S3 path) |

### Profiles

**`awsbatch`** - For cloud execution via Seqera Platform

Configured in [nextflow.config](nextflow.config):

- Executor: AWS Batch
- Container: ubuntu:22.04

**`docker`** - For local testing

Configured in [nextflow.config](nextflow.config):

- Docker enabled
- Container: ubuntu:22.04

### SQS Configuration

For detailed SQS setup and configuration, see [README-SQS.md](README-SQS.md).

## Files

- [main.nf](main.nf) - Main workflow definition
- [main-sqs.nf](main-sqs.nf) - Workflow with SQS integration (workflow.onComplete hook)
- [nextflow.config](nextflow.config) - Base workflow configuration
- [sqs.config](sqs.config) - SQS configuration reference (deprecated, see main-sqs.nf)
- [seqera.config](seqera.config) - Seqera Platform profile configuration
- [test-local.sh](test-local.sh) - Local test runner script
- [test-tw.sh](test-tw.sh) - Seqera Platform workflow launcher (basic)
- [test-sqs.sh](test-sqs.sh) - Seqera Platform workflow launcher with SQS integration
- [lib/tw-common.sh](lib/tw-common.sh) - Shared library for workflow launchers

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

**SQS issues:**

- See [README-SQS.md](README-SQS.md) for troubleshooting

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

### Adjust Resources

Edit [nextflow.config](nextflow.config) within the `awsbatch` profile:

```groovy
awsbatch {
    process {
        executor = 'awsbatch'
        container = 'ubuntu:22.04'
        cpus = 2
        memory = '1 GB'
    }
}
```

Note: AWS region is determined by your compute environment in Seqera Platform.

## License

See [LICENSE](LICENSE) file.
