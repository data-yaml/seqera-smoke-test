# SQS Integration for Seqera Platform

This repository includes a post-run script that sends workflow metadata to an SQS queue after workflow completion.

## Architecture

1. **Bash script** ([scripts/post-run-sqs.sh](scripts/post-run-sqs.sh)) - Minimal launcher that downloads Python script
2. **Python script** ([scripts/post_run_sqs.py](scripts/post_run_sqs.py)) - Main integration logic:
   - Fetches workflow details from Seqera Platform API using `TOWER_*` environment variables
   - Extracts params (including `sqs_queue_url`, `outdir`) from API response
   - Waits for and parses WRROC metadata file
   - Sends comprehensive metadata to SQS queue

## Configuration

### Required Parameters

When launching the workflow in Seqera Platform, you must specify:

```bash
--params.sqs_queue_url 'https://sqs.us-east-1.amazonaws.com/ACCOUNT/QUEUE-NAME'
```

### Optional Parameters

```bash
--params.sqs_region 'us-east-1'  # Defaults to us-east-1
--params.outdir 's3://bucket/path'  # Where outputs and WRROC file are written
```

### Seqera Platform Configuration

1. **Launch Parameters** - Add the SQS parameters when launching:

   ```yaml
   params:
     outdir: s3://your-bucket/outputs
     sqs_queue_url: https://sqs.us-east-1.amazonaws.com/123456789/your-queue
     sqs_region: us-east-1
   ```

2. **Post-Run Hook** - Configure in Seqera Platform:

   ```bash
   curl -sSfL https://raw.githubusercontent.com/data-yaml/seqera-smoke-test/parse-wrroc/scripts/post-run-sqs.sh | bash
   ```

## Metadata Sent to SQS

The script sends a comprehensive metadata payload including:

### From Seqera Platform API

- `api_params` - Resolved parameters (including `outdir`, `sqs_queue_url`)
- `api_run_name`, `api_status`, `api_session_id`
- `api_launch_id`, `api_launch_pipeline`, `api_launch_revision`
- `api_compute_env_id`, `api_workdir`, `api_duration`

### From TOWER_* Environment Variables

- `tower_workflow_id`, `tower_run_name`, `tower_project_id`
- `tower_workspace_id`, `tower_user_id`
- `tower_workflow_status`, `tower_workflow_start`, `tower_workflow_complete`
- `tower_pipeline`, `tower_pipeline_revision`, `tower_nextflow_version`

### From WRROC Metadata File

- `wrroc_name`, `wrroc_date_published`, `wrroc_license`
- `wrroc_author_name`, `wrroc_author_orcid`
- `wrroc_run_id`, `wrroc_start_time`, `wrroc_end_time`
- `wrroc_runtime_platform`, `wrroc_programming_language`

## Example SQS Message

```json
{
  "source_prefix": "s3://quilt-demos/test/tower/",
  "metadata": {
    "tower_workflow_id": "5LgHpGya14LRew",
    "api_params": {
      "outdir": "s3://quilt-demos/test/tower",
      "sqs_queue_url": "https://sqs.us-east-1.amazonaws.com/850787717197/queue"
    },
    "api_config_text": "params { ... }",
    "wrroc_author_name": "Ernest Prabhakar",
    ...
  },
  "commit_message": "Seqera Platform workflow completed at 2025-12-02 23:15:00"
}
```

## Testing

Test the API integration locally:

```bash
export TOWER_ACCESS_TOKEN="your-token"
export TOWER_WORKFLOW_ID="workflow-id"
export TOWER_WORKSPACE_ID="workspace-id"

python3 scripts/post_run_sqs.py
```

## Requirements

- Python 3.7+ (available in Nextflow compute environment)
- AWS CLI (for S3 operations and SQS sending)
- AWS credentials with permissions to:
  - Read from S3 (for WRROC file)
  - Send messages to SQS queue
