#!/bin/bash
# Seqera Platform Smoke Test - SQS Integration with Post-Run Script
#
# This script launches a workflow with a Seqera Platform post-run script that:
# 1. Waits for WRROC metadata file from nf-prov plugin
# 2. Extracts WRROC metadata
# 3. Sends SQS notification with workflow + WRROC metadata

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/tw-common.sh"

# Constants
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA"
QUEUE_REGION="us-east-1"
POST_RUN_SCRIPT="$SCRIPT_DIR/post-run-sqs-minimal.sh"

# Parse command line arguments
YES_FLAG=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)
            YES_FLAG=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--yes|-y]"
            exit 1
            ;;
    esac
done

print_header "Seqera Platform Smoke Test - SQS Integration (Post-Run Script)"

# Load environment variables from .env if it exists
load_env_file

# Check prerequisites (CLI, login, git status) - MUST be first
check_prerequisites

# NOTE: AWS CLI validation intentionally skipped!
# SQS messages are sent from within the Seqera Platform compute environment,
# NOT from this local machine. The compute environment must have:
# 1. AWS credentials (IAM role or configured credentials)
# 2. Permissions: sqs:SendMessage on the target queue
#
# Local AWS credentials are NOT used and NOT required for this test.

# Check and prompt for TOWER_ACCESS_TOKEN
get_or_prompt_token

# Check for workspaces and get/prompt for workspace
get_or_prompt_workspace

# Check for compute environments and get/prompt for compute environment
get_or_prompt_compute_env

# Get or prompt for S3 bucket
PARAMS_FILE="work/params.yaml"
get_or_prompt_s3_bucket "$PARAMS_FILE"

echo ""

# Get compute environment details if a specific compute env is set
if [ -n "$COMPUTE_ENV" ]; then
    echo "Fetching compute environment details..."
    COMPUTE_ENV_DETAILS=$(tw compute-envs view --name="$COMPUTE_ENV" --workspace="$WORKSPACE" 2>/dev/null)

    # Extract region and workDir from the JSON configuration
    CE_REGION=$(echo "$COMPUTE_ENV_DETAILS" | grep -o '"region" : "[^"]*"' | cut -d'"' -f4)
    CE_WORKDIR=$(echo "$COMPUTE_ENV_DETAILS" | grep -o '"workDir" : "[^"]*"' | cut -d'"' -f4)

    echo ""
fi

# Verify post-run script exists
if [ ! -f "$POST_RUN_SCRIPT" ]; then
    echo "ERROR: Post-run script not found: $POST_RUN_SCRIPT"
    exit 1
fi

echo "Configuration:"
echo "  Pipeline: https://github.com/data-yaml/seqera-smoke-test"
echo "  Branch: $CURRENT_BRANCH"
echo "  Main Script: main.nf"
echo "  Profile: awsbatch"
echo "  Compute Environment: ${COMPUTE_ENV:-default}"
if [ -n "$CE_REGION" ]; then
    echo "  Region: $CE_REGION"
fi
if [ -n "$CE_WORKDIR" ]; then
    echo "  Work Directory: $CE_WORKDIR"
fi
echo "  Output: $S3_BUCKET"
echo "  SQS Queue: $SQS_QUEUE_URL"
echo "  Post-Run Script: post-run-sqs-minimal.sh (downloads Python script from GitHub)"
echo ""

# Confirm before launching
if [ "$YES_FLAG" = true ]; then
    echo "Launching workflow (--yes flag)..."
else
    read -p "Launch workflow? (y/N): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""
echo "Launching workflow via Seqera Platform..."
echo ""

# Write params file
write_params_file "$PARAMS_FILE" "$S3_BUCKET"

# Launch the workflow with main.nf and post-run script
echo "Submitting workflow with post-run script..."
if [ -n "$COMPUTE_ENV" ]; then
    LAUNCH_OUTPUT=$(tw launch https://github.com/data-yaml/seqera-smoke-test \
      --workspace="$WORKSPACE" \
      --revision="$CURRENT_BRANCH" \
      --compute-env="$COMPUTE_ENV" \
      --profile=awsbatch \
      --params-file="$PARAMS_FILE" \
      --main-script=main.nf \
      --post-run="$POST_RUN_SCRIPT" 2>&1)
    LAUNCH_EXIT_CODE=$?
else
    LAUNCH_OUTPUT=$(tw launch https://github.com/data-yaml/seqera-smoke-test \
      --workspace="$WORKSPACE" \
      --revision="$CURRENT_BRANCH" \
      --profile=awsbatch \
      --params-file="$PARAMS_FILE" \
      --main-script=main.nf \
      --post-run="$POST_RUN_SCRIPT" 2>&1)
    LAUNCH_EXIT_CODE=$?
fi

echo "$LAUNCH_OUTPUT"

# Check if launch failed
if [ $LAUNCH_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "========================================"
    echo "ERROR: Workflow launch failed!"
    echo "========================================"
    echo ""
    exit 1
fi

# Extract run ID from the output (format: "Workflow <RUN_ID> submitted")
RUN_ID=$(echo "$LAUNCH_OUTPUT" | grep -oE 'Workflow [0-9a-zA-Z]+ submitted' | grep -oE '[0-9a-zA-Z]{14,}' | head -1)

echo ""
echo "========================================"
echo "Workflow Submitted!"
echo "========================================"
echo ""

if [ -n "$RUN_ID" ]; then
    echo "Run ID: $RUN_ID"
else
    echo "⚠ Could not extract run ID from output."
fi

echo ""

# Wait for workflow completion
wait_for_workflow_completion() {
    if [ -z "$RUN_ID" ]; then
        echo "Cannot wait for workflow completion without run ID."
        echo "Please check workflow status manually:"
        echo "  tw runs view --workspace='$WORKSPACE'"
        return 1
    fi

    echo "Waiting for workflow completion..."
    echo "Run ID: $RUN_ID"
    echo ""

    local max_wait=600  # 10 minutes
    local interval=30   # Check every 30 seconds
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        # Get workflow status
        WORKFLOW_STATUS=$(tw runs view -i "$RUN_ID" --workspace="$WORKSPACE" 2>/dev/null | grep "Status" | awk '{print $3}')

        if [ -n "$WORKFLOW_STATUS" ]; then
            echo "Status: $WORKFLOW_STATUS (elapsed: ${elapsed}s)"

            case "$WORKFLOW_STATUS" in
                SUCCEEDED)
                    echo ""
                    echo "✓ Workflow completed successfully!"
                    echo ""
                    return 0
                    ;;
                FAILED)
                    echo ""
                    echo "ERROR: Workflow failed with status: FAILED"
                    echo ""
                    echo "View details:"
                    echo "  tw runs view -i $RUN_ID --workspace='$WORKSPACE'"
                    echo ""
                    exit 1
                    ;;
                CANCELLED)
                    echo ""
                    echo "ERROR: Workflow was cancelled."
                    echo ""
                    exit 1
                    ;;
                RUNNING|SUBMITTED)
                    # Continue waiting
                    ;;
                *)
                    echo "Unknown status: $WORKFLOW_STATUS"
                    ;;
            esac
        else
            echo "Could not retrieve workflow status (elapsed: ${elapsed}s)"
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo ""
    echo "Timeout: Workflow did not complete within $max_wait seconds."
    echo "Check status manually:"
    echo "  tw runs view -i $RUN_ID --workspace='$WORKSPACE'"
    echo ""
    exit 1
}

# Verify SQS message delivery
verify_sqs_message() {
    echo "Post-run script should have sent SQS message."
    echo ""
    echo "To verify SQS message delivery:"
    echo "  1. Check workflow logs for 'SQS Integration SUCCESS' message"
    echo "  2. Query SQS queue for messages"
    echo ""
    echo "Checking workflow logs..."
    echo ""

    # Get workflow logs
    if tw runs view -i "$RUN_ID" --workspace="$WORKSPACE" 2>/dev/null | grep -q "SQS Integration SUCCESS"; then
        echo "✓ Found SQS success message in workflow logs"
        echo ""
        return 0
    else
        echo "⚠ Could not find SQS success message in workflow logs"
        echo ""
        echo "This may mean:"
        echo "  1. Post-run script is still executing"
        echo "  2. Post-run script failed"
        echo "  3. Logs not yet available"
        echo ""
        echo "Check full logs:"
        echo "  tw runs view -i $RUN_ID --workspace='$WORKSPACE'"
        echo ""
        return 1
    fi
}

# Wait for workflow completion
wait_for_workflow_completion

# Give post-run script time to execute
echo "Waiting 30 seconds for post-run script to complete..."
sleep 30

# Verify SQS message
verify_sqs_message
SQS_VERIFY_EXIT=$?

# Display final results
echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo ""
echo "Run ID: $RUN_ID"
echo "Workspace: $WORKSPACE"
echo "Output: $S3_BUCKET"
echo ""

if [ $SQS_VERIFY_EXIT -eq 0 ]; then
    echo "✓ Workflow completed successfully"
    echo "✓ Post-run script executed (SQS message sent)"
else
    echo "✓ Workflow completed successfully"
    echo "⚠ Post-run script status unclear"
fi

echo ""
echo "Next steps:"
echo "1. View workflow details: tw runs view -i $RUN_ID --workspace='$WORKSPACE'"
echo "2. View workflow tasks: tw runs view -i $RUN_ID tasks --workspace='$WORKSPACE'"
echo "3. Verify S3 output: aws s3 ls $S3_BUCKET/"
echo "4. Check SQS queue for message: aws sqs receive-message --queue-url $SQS_QUEUE_URL --region $QUEUE_REGION"
echo ""
