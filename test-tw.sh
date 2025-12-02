#!/bin/bash
# Note: set -e removed - we manually check exit codes throughout the script

# Get script directory and source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/tw-common.sh"

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

print_header "Seqera Platform Smoke Test - tw CLI"

# Load environment variables from .env if it exists
load_env_file

# Check prerequisites (CLI, login, git status) - MUST be first
check_prerequisites

# Check and prompt for TOWER_ACCESS_TOKEN
get_or_prompt_token

# Check for workspaces and get/prompt for workspace
get_or_prompt_workspace

# Check for compute environments and get/prompt for compute environment
get_or_prompt_compute_env

# Get or prompt for S3 bucket
PARAMS_FILE="work/params.yaml"
get_or_prompt_s3_bucket "$PARAMS_FILE"

# Get compute environment details if a specific compute env is set
if [ -n "$COMPUTE_ENV" ]; then
    echo "Fetching compute environment details..."
    COMPUTE_ENV_DETAILS=$(tw compute-envs view --name="$COMPUTE_ENV" --workspace="$WORKSPACE" 2>/dev/null)

    # Extract region and workDir from the JSON configuration
    CE_REGION=$(echo "$COMPUTE_ENV_DETAILS" | grep -o '"region" : "[^"]*"' | cut -d'"' -f4)
    CE_WORKDIR=$(echo "$COMPUTE_ENV_DETAILS" | grep -o '"workDir" : "[^"]*"' | cut -d'"' -f4)

    echo ""
fi

echo "Configuration:"
echo "  Pipeline: https://github.com/data-yaml/seqera-smoke-test"
echo "  Branch: $CURRENT_BRANCH"
echo "  Profile: awsbatch"
echo "  Compute Environment: ${COMPUTE_ENV:-default}"
if [ -n "$CE_REGION" ]; then
    echo "  Region: $CE_REGION"
fi
if [ -n "$CE_WORKDIR" ]; then
    echo "  Work Directory: $CE_WORKDIR"
fi
echo "  Output: $S3_BUCKET"
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

# Launch the workflow with the detected branch and capture output
if [ -n "$COMPUTE_ENV" ]; then
    LAUNCH_OUTPUT=$(tw launch https://github.com/data-yaml/seqera-smoke-test \
      --workspace="$WORKSPACE" \
      --revision="$CURRENT_BRANCH" \
      --compute-env="$COMPUTE_ENV" \
      --profile=awsbatch \
      --params-file="$PARAMS_FILE" 2>&1)
    LAUNCH_EXIT_CODE=$?
else
    LAUNCH_OUTPUT=$(tw launch https://github.com/data-yaml/seqera-smoke-test \
      --workspace="$WORKSPACE" \
      --revision="$CURRENT_BRANCH" \
      --profile=awsbatch \
      --params-file="$PARAMS_FILE" 2>&1)
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
    echo ""
    echo "Next steps:"
    echo "1. View workflow details: tw runs view -i $RUN_ID --workspace='$WORKSPACE'"
    echo "2. View workflow tasks: tw runs view -i $RUN_ID tasks --workspace='$WORKSPACE'"
    echo "3. Verify S3 output: aws s3 ls $S3_BUCKET/"
else
    echo "⚠ Could not extract run ID from output."
    echo ""
    echo "Next steps:"
    echo "1. View workflow details: tw runs view -i <run-id> --workspace='$WORKSPACE'"
    echo "2. View workflow tasks: tw runs view -i <run-id> tasks --workspace='$WORKSPACE'"
    echo "3. Verify S3 output: aws s3 ls $S3_BUCKET/"
fi

echo ""
echo "Note: Workspace saved to $ENV_FILE for next run."
echo "      Remember to use --workspace='$WORKSPACE' with tw commands."
echo ""
echo "If you see 'No available compute environment' error,"
echo "you need to configure a compute environment in Seqera Platform."
echo "Use: tw compute-envs list --workspace='$WORKSPACE'"
echo ""
