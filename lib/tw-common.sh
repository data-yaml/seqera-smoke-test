#!/bin/bash
# Shared library for Seqera Platform workflow test scripts

# Global variables
YES_FLAG=${YES_FLAG:-false}
ENV_FILE=${ENV_FILE:-.env}

# Print formatted header
print_header() {
    local message="$1"
    echo "========================================"
    echo "$message"
    echo "========================================"
    echo ""
}

# Check if tw CLI is installed
check_tw_cli() {
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
}

# Check if logged in to Seqera Platform
check_tw_login() {
    if ! tw info &> /dev/null; then
        echo "ERROR: Not logged in to Seqera Platform."
        echo "Please run: tw login"
        echo ""
        exit 1
    fi
    echo "✓ Logged in to Seqera Platform"
    echo ""
}

# Check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        echo "ERROR: AWS CLI not found but required for SQS integration."
        echo ""
        echo "Installation:"
        echo "  macOS:     brew install awscli"
        echo "  Linux:     https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo ""
        exit 1
    fi
    echo "✓ AWS CLI found"
}

# Load environment variables from .env file
load_env_file() {
    if [ -f "$ENV_FILE" ]; then
        echo "Loading environment variables from $ENV_FILE"
        set -a
        source "$ENV_FILE"
        set +a
        echo ""
    fi
}

# Save key=value to .env file
save_to_env() {
    local key="$1"
    local value="$2"

    if [ -f "$ENV_FILE" ]; then
        # Update existing key or append new one
        if grep -q "^${key}=" "$ENV_FILE"; then
            grep -v "^${key}=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
            echo "${key}=${value}" >> "${ENV_FILE}.tmp"
            mv "${ENV_FILE}.tmp" "$ENV_FILE"
        else
            echo "${key}=${value}" >> "$ENV_FILE"
        fi
    else
        # Create new file with header
        {
            echo "# Seqera Platform credentials"
            echo "# Generated on $(date)"
            echo "${key}=${value}"
        } > "$ENV_FILE"
    fi
}

# Ensure .env is in .gitignore
ensure_gitignore() {
    if [ -f ".gitignore" ]; then
        if ! grep -q "^\.env$" .gitignore; then
            echo ".env" >> .gitignore
            echo "✓ Added .env to .gitignore"
        fi
    else
        echo ".env" > .gitignore
        echo "✓ Created .gitignore with .env"
    fi
}

# Get or prompt for TOWER_ACCESS_TOKEN
get_or_prompt_token() {
    if [ -z "$TOWER_ACCESS_TOKEN" ]; then
        echo "TOWER_ACCESS_TOKEN not found in environment."
        echo "Enter your Seqera Platform access token:"
        read -r TOWER_ACCESS_TOKEN

        if [ -z "$TOWER_ACCESS_TOKEN" ]; then
            echo "ERROR: TOWER_ACCESS_TOKEN is required."
            exit 1
        fi

        # Save to .env file
        save_to_env "TOWER_ACCESS_TOKEN" "$TOWER_ACCESS_TOKEN"
        ensure_gitignore
        echo "✓ Credentials saved to $ENV_FILE"
    fi

    echo "✓ TOWER_ACCESS_TOKEN configured"
    export TOWER_ACCESS_TOKEN

    # Ensure token is in .env file
    if [ ! -f "$ENV_FILE" ] || ! grep -q "^TOWER_ACCESS_TOKEN=" "$ENV_FILE"; then
        save_to_env "TOWER_ACCESS_TOKEN" "$TOWER_ACCESS_TOKEN"
        ensure_gitignore
        echo "✓ Credentials saved to $ENV_FILE"
    fi

    echo ""
}

# Get or prompt for workspace
get_or_prompt_workspace() {
    echo "Checking workspaces..."
    tw workspaces list
    if [ $? -ne 0 ]; then
        echo "ERROR: Unable to list workspaces."
        exit 1
    fi

    echo ""

    # Check if workspace is already saved
    if [ -f "$ENV_FILE" ] && grep -q "^TOWER_WORKSPACE_ID=" "$ENV_FILE"; then
        SAVED_WORKSPACE=$(grep "^TOWER_WORKSPACE_ID=" "$ENV_FILE" | cut -d'=' -f2-)
        echo "Found saved workspace: $SAVED_WORKSPACE"
        echo ""

        if [ "$YES_FLAG" = true ]; then
            WORKSPACE="$SAVED_WORKSPACE"
            echo "Using workspace: $WORKSPACE (--yes flag)"
        else
            read -p "Use this workspace? (Y/n): " -n 1 -r
            echo ""
            echo ""

            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                WORKSPACE="$SAVED_WORKSPACE"
                echo "Using workspace: $WORKSPACE"
            else
                # Prompt for new workspace
                echo "Enter workspace in Organization/Workspace format"
                echo "(e.g., Quilt_Data/hackathon_2023):"
                read -r WORKSPACE

                if [ -z "$WORKSPACE" ]; then
                    echo "ERROR: Workspace is required."
                    exit 1
                fi

                # Save to .env file
                save_to_env "TOWER_WORKSPACE_ID" "$WORKSPACE"
                echo "✓ Workspace saved to $ENV_FILE"
            fi
        fi
    else
        # No saved workspace - error if --yes flag is used
        if [ "$YES_FLAG" = true ]; then
            echo "ERROR: --yes flag requires TOWER_WORKSPACE_ID in $ENV_FILE"
            echo "Run without --yes first to configure workspace."
            exit 1
        fi

        # Prompt for workspace
        echo "Enter workspace in Organization/Workspace format"
        echo "(e.g., Quilt_Data/hackathon_2023):"
        read -r WORKSPACE

        if [ -z "$WORKSPACE" ]; then
            echo "ERROR: Workspace is required."
            exit 1
        fi

        # Save workspace to .env
        echo ""
        echo "Saving workspace to $ENV_FILE for future use..."
        save_to_env "TOWER_WORKSPACE_ID" "$WORKSPACE"
        echo "✓ Workspace saved"
    fi

    echo ""
}

# Get or prompt for compute environment
get_or_prompt_compute_env() {
    echo "Checking compute environments..."
    COMPUTE_ENVS_OUTPUT=$(tw compute-envs list --workspace="$WORKSPACE" 2>&1)

    if echo "$COMPUTE_ENVS_OUTPUT" | grep -q "No compute environments found"; then
        echo "⚠ No compute environments found in workspace: $WORKSPACE"
        echo ""
        echo "You need to configure a compute environment before launching workflows."
        echo "Visit Seqera Platform to add a compute environment, or use:"
        echo "  tw compute-envs add --help"
        echo ""
        exit 1
    fi

    # Display available compute environments
    echo "$COMPUTE_ENVS_OUTPUT"
    echo ""

    # Check if there's a saved compute environment
    if [ -f "$ENV_FILE" ] && grep -q "^TOWER_COMPUTE_ENV=" "$ENV_FILE"; then
        SAVED_COMPUTE_ENV=$(grep "^TOWER_COMPUTE_ENV=" "$ENV_FILE" | cut -d'=' -f2-)
        echo "Found saved compute environment: $SAVED_COMPUTE_ENV"
        echo ""

        if [ "$YES_FLAG" = true ]; then
            COMPUTE_ENV="$SAVED_COMPUTE_ENV"
            echo "Using compute environment: $COMPUTE_ENV (--yes flag)"
        else
            read -p "Use this compute environment? (Y/n): " -n 1 -r
            echo ""
            echo ""

            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                COMPUTE_ENV="$SAVED_COMPUTE_ENV"
                echo "Using compute environment: $COMPUTE_ENV"
            else
                # Prompt for new compute environment
                echo "Enter compute environment name from the list above:"
                read -r COMPUTE_ENV

                if [ -z "$COMPUTE_ENV" ]; then
                    echo "ERROR: Compute environment is required."
                    exit 1
                fi

                # Save to .env file
                save_to_env "TOWER_COMPUTE_ENV" "$COMPUTE_ENV"
                echo "✓ Compute environment saved to $ENV_FILE"
            fi
        fi
    else
        # No saved compute environment
        if [ "$YES_FLAG" = true ]; then
            # Use default/primary when --yes is set
            COMPUTE_ENV=""
            echo "Using workspace default/primary compute environment (--yes flag)"
        else
            # Prompt for compute environment
            echo "Enter compute environment name from the list above"
            echo "(or press Enter to use primary/default):"
            read -r COMPUTE_ENV

            if [ -n "$COMPUTE_ENV" ]; then
                # Save compute environment to .env
                echo ""
                echo "Saving compute environment to $ENV_FILE for future use..."
                save_to_env "TOWER_COMPUTE_ENV" "$COMPUTE_ENV"
                echo "✓ Compute environment saved"
            else
                echo "Using workspace default/primary compute environment"
            fi
        fi
    fi

    echo ""
}

# Get or prompt for S3 bucket
get_or_prompt_s3_bucket() {
    local params_file="$1"

    # Create work directory if it doesn't exist
    mkdir -p "$(dirname "$params_file")"

    # Check if params file already exists and offer to reuse
    if [ -f "$params_file" ]; then
        EXISTING_OUTDIR=$(grep "^outdir:" "$params_file" | cut -d' ' -f2- | tr -d ' ')
        echo "Found existing params file with:"
        echo "  outdir: $EXISTING_OUTDIR"
        echo ""

        if [ "$YES_FLAG" = true ]; then
            # Reuse existing bucket when --yes is set
            S3_BUCKET="$EXISTING_OUTDIR"
            echo "Reusing: $S3_BUCKET (--yes flag)"
            echo ""
        else
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
        fi
    else
        # No existing params file
        if [ "$YES_FLAG" = true ]; then
            echo "ERROR: --yes flag requires existing params file with S3 bucket"
            echo "Run without --yes first to configure S3 bucket."
            exit 1
        fi

        # Prompt for S3 bucket
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
}

# Detect current git branch
detect_git_branch() {
    local branch=$(git branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        branch="main"
        echo "⚠ Could not detect git branch, defaulting to: $branch" >&2
    fi
    echo "$branch"
}

# Write params file
write_params_file() {
    local params_file="$1"
    local s3_bucket="$2"

    cat > "$params_file" <<EOF
outdir: $s3_bucket
EOF

    echo "Parameters saved to: $params_file"
    echo ""
}

# Check for uncommitted or unpushed changes
check_git_status() {
    # Check if we're in a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo "⚠ Not a git repository, skipping git status check"
        echo ""
        return 0
    fi

    # Get current branch
    local branch=$(git branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        echo "⚠ Could not detect git branch, skipping git status check"
        echo ""
        return 0
    fi

    # Check if branch exists on remote
    if ! git rev-parse --verify "origin/$branch" > /dev/null 2>&1; then
        echo "ERROR: Branch '$branch' does not exist on remote 'origin'"
        echo ""
        echo "The workflow will fail because Seqera Platform cannot access this branch."
        echo ""
        echo "Push the branch first:"
        echo "  git push -u origin $branch"
        echo ""
        exit 1
    fi

    # Check for uncommitted changes
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "ERROR: You have uncommitted changes"
        echo ""
        git status --short
        echo ""
        echo "The workflow will use the version from GitHub, which does not include"
        echo "your local uncommitted changes."
        echo ""
        echo "Commit your changes first:"
        echo "  git add ."
        echo "  git commit -m 'Your commit message'"
        echo "  git push origin $branch"
        echo ""
        exit 1
    fi

    # Check for unpushed commits
    local unpushed=$(git log --oneline "origin/$branch..HEAD" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$unpushed" -gt 0 ]; then
        echo "Found $unpushed unpushed commit(s)"
        echo ""
        git log --oneline "origin/$branch..HEAD"
        echo ""
        echo "Pushing to origin/$branch..."

        if git push origin "$branch"; then
            echo ""
            echo "✓ Successfully pushed $unpushed commit(s) to origin/$branch"
            echo ""
            echo "Waiting 3 seconds for GitHub to process push..."
            sleep 3
            echo ""
        else
            echo ""
            echo "ERROR: Failed to push commits to origin/$branch"
            echo ""
            echo "Please resolve the issue and try again."
            echo ""
            exit 1
        fi
    else
        echo "✓ Git status clean (branch: $branch, synced with origin)"
        echo ""
    fi
}
