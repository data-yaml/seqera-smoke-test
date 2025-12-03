#!/bin/bash
# Post-run script for Seqera Platform
# This script runs after workflow completion to send an SQS notification with WRROC metadata
#
# Required environment variables (provided by Seqera Platform):
#   - NXF_WORK: Nextflow work directory
#   - NXF_PARAMS_outdir: Output directory (from params.outdir)
#
# This script:
# 1. Checks AWS CLI availability and credentials
# 2. Waits for and detects WRROC file from nf-prov plugin
# 3. Extracts WRROC metadata
# 4. Sends SQS message with workflow + WRROC metadata

set -euo pipefail

# ========================================
# Configuration
# ========================================
readonly QUEUE_URL="https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA"
readonly REGION="us-east-1"
readonly AWS_CMD="aws"
readonly MAX_WAIT_SECONDS=60
readonly CHECK_INTERVAL_MS=500
readonly SEPARATOR="========================================"

# Get output directory from Nextflow params
OUTDIR="${NXF_PARAMS_outdir:-}"

if [ -z "$OUTDIR" ]; then
    echo "ERROR: NXF_PARAMS_outdir not set"
    echo "This script must be run as a Seqera Platform post-run script"
    exit 1
fi

# ========================================
# Helper Functions
# ========================================

print_separator() {
    echo "$SEPARATOR"
}

print_header() {
    echo ""
    print_separator
    echo "$1"
    print_separator
    echo ""
}

# Check AWS CLI availability
check_aws_cli() {
    echo "Checking AWS CLI availability..."
    if ! command -v "$AWS_CMD" &> /dev/null; then
        print_header "ERROR: AWS CLI Not Available"
        echo "The AWS CLI is not installed or not in PATH in this compute environment."
        echo ""
        echo "Required: AWS CLI must be installed in the compute environment container/AMI"
        echo ""
        exit 1
    fi

    local aws_version
    aws_version=$("$AWS_CMD" --version 2>&1)
    echo "✓ AWS CLI found: $aws_version"
    echo ""
}

# Check AWS credentials
check_aws_credentials() {
    echo "Checking AWS credentials..."
    if ! "$AWS_CMD" sts get-caller-identity &> /dev/null; then
        print_header "ERROR: AWS Credentials Not Configured"
        echo "AWS credentials are not available in this compute environment."
        echo ""
        echo "Required: Compute environment must have:"
        echo "  - IAM instance role (for AWS Batch/EC2), OR"
        echo "  - AWS credentials configured in environment"
        echo ""
        exit 1
    fi

    local identity
    identity=$("$AWS_CMD" sts get-caller-identity 2>&1)
    echo "✓ AWS credentials found"
    echo "Identity: $identity"
    echo ""
}

# Check if file exists (supports both local and S3 paths)
file_exists() {
    local path="$1"

    if [[ "$path" =~ ^s3:// ]]; then
        "$AWS_CMD" s3 ls "$path" &> /dev/null
    else
        [ -f "$path" ] && [ -s "$path" ]
    fi
}

# Get file size (supports both local and S3 paths)
get_file_size() {
    local path="$1"

    if [[ "$path" =~ ^s3:// ]]; then
        local output
        output=$("$AWS_CMD" s3 ls "$path" 2>&1)
        echo "$output" | awk '{print $3}'
    else
        stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null
    fi
}

# List directory contents
list_directory() {
    local path="$1"

    echo "Listing directory contents: $path"

    if [[ "$path" =~ ^s3:// ]]; then
        "$AWS_CMD" s3 ls "$path" 2>&1 | sed 's/^/  /'
    else
        ls -lh "$path" 2>&1 | sed 's/^/  /'
    fi
    echo ""
}

# Wait for WRROC file to be written
wait_for_wrroc_file() {
    local wrroc_path="$1"
    local path_type

    [[ "$wrroc_path" =~ ^s3:// ]] && path_type="S3" || path_type="Local"

    echo "Waiting for WRROC file to be written by nf-prov plugin..."
    echo "Target path: $wrroc_path"
    echo "Path type: $path_type"
    echo ""

    # Extract directory path
    local dir_path
    dir_path="${wrroc_path%/*}"
    [ "$dir_path" = "$wrroc_path" ] && dir_path="."

    list_directory "$dir_path"

    local attempts=$((MAX_WAIT_SECONDS * 1000 / CHECK_INTERVAL_MS))
    local found=false

    for ((i=0; i<attempts; i++)); do
        if file_exists "$wrroc_path"; then
            local file_size
            file_size=$(get_file_size "$wrroc_path")
            echo "✓ WRROC file found: $wrroc_path"
            echo "  File size: $file_size bytes"
            found=true
            break
        fi
        sleep $(echo "scale=3; $CHECK_INTERVAL_MS / 1000" | bc)
    done

    if [ "$found" = false ]; then
        print_header "WARNING: WRROC File Not Found"
        echo "Expected path: $wrroc_path"
        echo "Waited: $MAX_WAIT_SECONDS seconds"
        echo ""
        echo "The nf-prov plugin should have created this file."
        echo "Proceeding with SQS notification, but WRROC file may be missing."
        print_separator
    fi

    echo ""
    echo "$found"
}

# Read and parse WRROC metadata
extract_wrroc_metadata() {
    local wrroc_path="$1"
    local temp_file="/tmp/wrroc-metadata.json"

    echo "Extracting WRROC metadata..."

    # Download S3 file if needed
    if [[ "$wrroc_path" =~ ^s3:// ]]; then
        if ! "$AWS_CMD" s3 cp "$wrroc_path" "$temp_file" &> /dev/null; then
            echo "⚠ Warning: Failed to download WRROC file from S3"
            echo "{}"
            return
        fi
        wrroc_path="$temp_file"
    fi

    # Parse WRROC JSON and extract metadata
    python3 -c "
import json
import sys

try:
    with open('$wrroc_path') as f:
        wrroc = json.load(f)

    metadata = {}
    graph = wrroc.get('@graph', [])

    # Find root dataset
    root = next((e for e in graph if e.get('@id') == './'), None)
    if root:
        metadata['wrroc_name'] = root.get('name')
        metadata['wrroc_date_published'] = root.get('datePublished')
        metadata['wrroc_license'] = root.get('license')

        author_id = root.get('author', {}).get('@id')
        if author_id:
            author = next((e for e in graph if e.get('@id') == author_id), None)
            if author:
                metadata['wrroc_author_name'] = author.get('name')
                metadata['wrroc_author_orcid'] = author_id

    # Find workflow run
    workflow_run = next((e for e in graph if e.get('@type') == 'CreateAction' and
                        e.get('name', '').startswith('Nextflow workflow run')), None)
    if workflow_run:
        metadata['wrroc_run_id'] = workflow_run.get('@id', '').lstrip('#')
        metadata['wrroc_start_time'] = workflow_run.get('startTime')
        metadata['wrroc_end_time'] = workflow_run.get('endTime')

    # Find main workflow
    main_workflow = next((e for e in graph if e.get('@id') == 'main-sqs.nf'), None)
    if main_workflow:
        metadata['wrroc_runtime_platform'] = main_workflow.get('runtimePlatform')
        metadata['wrroc_programming_language'] = main_workflow.get('programmingLanguage', {}).get('@id')

    # Remove None values
    metadata = {k: v for k, v in metadata.items() if v is not None}

    print(json.dumps(metadata, indent=2))

except Exception as e:
    print('{}', file=sys.stderr)
    sys.exit(0)  # Don't fail the script
" 2>/dev/null || echo "{}"

    # Clean up temp file
    [ -f "$temp_file" ] && rm -f "$temp_file"
}

# Build SQS message body
build_sqs_message() {
    local wrroc_metadata="$1"

    # Extract Nextflow environment variables provided by Seqera Platform
    local nextflow_version="${NXF_VER:-unknown}"
    local workflow_name="${NXF_WORKFLOW_NAME:-unknown}"
    local workflow_id="${NXF_WORKFLOW_ID:-unknown}"
    local session_id="${NXF_SESSION_ID:-unknown}"
    local container="${NXF_CONTAINER:-none}"

    # Build message body
    python3 -c "
import json
import sys
from datetime import datetime

metadata = {
    'nextflow_version': '$nextflow_version',
    'workflow_name': '$workflow_name',
    'workflow_id': '$workflow_id',
    'session_id': '$session_id',
    'container': '$container',
    'success': True,  # Post-run script only runs on success
    'timestamp': datetime.utcnow().isoformat() + 'Z'
}

# Merge WRROC metadata
wrroc = json.loads('$wrroc_metadata')
metadata.update(wrroc)

message = {
    'source_prefix': '$OUTDIR/',
    'metadata': metadata,
    'commit_message': f'Seqera Platform smoke test completed at {datetime.now().strftime(\"%Y-%m-%d %H:%M:%S\")}'
}

print(json.dumps(message, indent=2))
"
}

# Send SQS message
send_sqs_message() {
    local message_json="$1"

    echo "Sending SQS message..."
    echo "Message body:"
    echo "$message_json"
    echo ""

    local response
    if response=$("$AWS_CMD" sqs send-message \
        --queue-url "$QUEUE_URL" \
        --region "$REGION" \
        --message-body "$message_json" 2>&1); then

        print_header "✓✓✓ SQS Integration SUCCESS ✓✓✓"
        echo "Message sent successfully to queue!"
        echo ""
        echo "Queue URL: $QUEUE_URL"
        echo "Region: $REGION"
        echo "Output folder: $OUTDIR"
        echo ""
        echo "AWS SQS Response:"
        echo "$response"
        print_separator
    else
        print_header "ERROR: SQS Message Send Failed"
        echo "Exit Code: $?"
        echo "Queue URL: $QUEUE_URL"
        echo "Region: $REGION"
        echo "Output folder: $OUTDIR"
        echo ""
        echo "Error details:"
        echo "$response"
        echo ""
        exit 1
    fi
}

# ========================================
# Main Execution
# ========================================

print_header "SQS Integration - Post-Run Script"
echo "Queue URL: $QUEUE_URL"
echo "Region: $REGION"
echo "Output folder: $OUTDIR"
echo ""

# Step 1: Check AWS CLI and credentials
check_aws_cli
check_aws_credentials

# Step 2: Wait for WRROC file
wrroc_path="${OUTDIR}/ro-crate-metadata.json"
wrroc_found=$(wait_for_wrroc_file "$wrroc_path")

# Step 3: Extract WRROC metadata if file exists
wrroc_metadata="{}"
if [ "$wrroc_found" = "true" ]; then
    wrroc_metadata=$(extract_wrroc_metadata "$wrroc_path")
    echo "Extracted WRROC metadata:"
    echo "$wrroc_metadata"
    echo ""
fi

# Step 4: Build and send SQS message
message_json=$(build_sqs_message "$wrroc_metadata")
send_sqs_message "$message_json"

echo ""
echo "✓ Post-run script completed successfully"
