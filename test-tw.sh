#!/bin/bash
set -e

echo "========================================"
echo "Seqera Platform Smoke Test - tw CLI"
echo "========================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v tw &> /dev/null; then
    echo "ERROR: tw CLI not found. Please install Seqera Platform CLI first."
    echo ""
    echo "Installation:"
    echo "  Homebrew:  brew install seqeralabs/tap/tw"
    echo "  Direct:    https://github.com/seqeralabs/tower-cli/releases/latest"
    echo ""
    echo "See: https://github.com/seqeralabs/tower-cli"
    echo ""
    exit 1
fi

echo "✓ Seqera Platform CLI found"

# Check tw login status
if ! tw info &> /dev/null; then
    echo "ERROR: Not logged in to Seqera Platform."
    echo "Please run: tw login"
    echo ""
    exit 1
fi

echo "✓ Logged in to Seqera Platform"
echo ""

# Check for workspaces
echo "Checking workspaces..."
tw workspaces list
if [ $? -ne 0 ]; then
    echo "ERROR: Unable to list workspaces."
    exit 1
fi

echo ""
echo "Enter workspace in Organization/Workspace format"
echo "(e.g., Quilt_Data/hackathon_2023):"
read -r WORKSPACE

if [ -z "$WORKSPACE" ]; then
    echo "ERROR: Workspace is required."
    exit 1
fi
echo ""

# Create work directory if it doesn't exist
mkdir -p work
PARAMS_FILE="work/params.yaml"

# Check if params file already exists and offer to reuse
if [ -f "$PARAMS_FILE" ]; then
    EXISTING_OUTDIR=$(grep "^outdir:" "$PARAMS_FILE" | cut -d' ' -f2- | tr -d ' ')
    echo "Found existing params file with:"
    echo "  outdir: $EXISTING_OUTDIR"
    echo ""
    read -p "Reuse this S3 bucket? (Y/n): " -n 1 -r
    echo ""
    echo ""

    if [[ $REPLY =~ ^[Nn]$ ]]; then
        # User wants to use new bucket - prompt for it
        echo "Enter S3 bucket path for workflow outputs"
        echo "(e.g., s3://my-bucket/smoke-test-results):"
        read -r S3_BUCKET
    else
        # Reuse existing bucket
        S3_BUCKET="$EXISTING_OUTDIR"
        echo "Reusing: $S3_BUCKET"
        echo ""
    fi
else
    # No existing params file - prompt for S3 bucket
    echo "Enter S3 bucket path for workflow outputs"
    echo "(e.g., s3://my-bucket/smoke-test-results):"
    read -r S3_BUCKET
fi

# Validate S3 bucket format
if [[ ! "$S3_BUCKET" =~ ^s3:// ]]; then
    echo ""
    echo "ERROR: S3 bucket path must start with 's3://'"
    echo "Example: s3://my-bucket/smoke-test-results"
    exit 1
fi

echo ""
echo "Configuration:"
echo "  Pipeline: https://github.com/data-yaml/seqera-smoke-test"
echo "  Profile: smoke"
echo "  Output: $S3_BUCKET"
echo ""

# Confirm before launching
read -p "Launch workflow? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Launching workflow via Seqera Platform..."
echo ""

# Write params file
cat > "$PARAMS_FILE" <<EOF
outdir: $S3_BUCKET
EOF

echo "Parameters saved to: $PARAMS_FILE"
echo ""

# Launch the workflow
tw launch https://github.com/data-yaml/seqera-smoke-test \
  --workspace="$WORKSPACE" \
  --profile smoke \
  --config seqera.config \
  --params-file "$PARAMS_FILE"

echo ""
echo "========================================"
echo "Workflow Submitted!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Monitor workflow progress: tw runs list"
echo "2. View workflow details: tw runs view <run-id>"
echo "3. Check logs: tw runs logs <run-id>"
echo "4. Verify S3 output: aws s3 ls $S3_BUCKET/"
echo ""
echo "Note: If you see 'No available compute environment' error,"
echo "you need to configure a compute environment in Seqera Platform."
echo "Use: tw compute-envs list"
echo ""
