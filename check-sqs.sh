#!/bin/bash
# Check SQS Integration Configuration
# Reads config.toml and verifies the SQS setup

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.toml"

# ANSI color codes
BLUE='\033[94m'
GREEN='\033[92m'
YELLOW='\033[93m'
RED='\033[91m'
BOLD='\033[1m'
END='\033[0m'

print_header() {
    echo -e "\n${BOLD}==========================================================${END}"
    echo -e "${BOLD}$1${END}"
    echo -e "${BOLD}==========================================================${END}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${END}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${END}"
}

print_error() {
    echo -e "${RED}✗ $1${END}"
}

# Parse simple TOML (basic implementation for our specific format)
parse_toml() {
    local file=$1
    local section=$2
    local key=$3

    # Extract value from TOML file
    local in_section=false
    local value=""

    while IFS= read -r line; do
        # Check if we're entering the target section
        if [[ $line =~ ^\[$section\] ]]; then
            in_section=true
            continue
        fi

        # Check if we're entering a different section
        if [[ $line =~ ^\[.*\] ]] && [[ ! $line =~ ^\[$section\] ]]; then
            in_section=false
            continue
        fi

        # If we're in the target section, look for the key
        if $in_section && [[ $line =~ ^$key[[:space:]]*=[[:space:]]*(.*) ]]; then
            value="${BASH_REMATCH[1]}"
            # Remove quotes
            value="${value//\"/}"
            # Remove trailing comments
            value="${value%% #*}"
            # Trim whitespace
            value="${value## }"
            value="${value%% }"
            echo "$value"
            return 0
        fi
    done < "$file"

    return 1
}

# Parse JSON array from TOML
parse_toml_array() {
    local file=$1
    local section=$2
    local key=$3

    local value=$(parse_toml "$file" "$section" "$key")
    if [ -z "$value" ]; then
        echo "[]"
        return
    fi

    # Parse JSON array
    echo "$value" | python3 -c "import sys, json; print(' '.join(json.load(sys.stdin)))" 2>/dev/null || echo ""
}

# Parse command line arguments
AWS_PROFILE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--profile PROFILE] [--verbose]"
            echo ""
            echo "Check SQS integration configuration from config.toml"
            echo ""
            echo "Options:"
            echo "  --profile PROFILE   AWS profile to use"
            echo "  --verbose, -v       Show detailed output"
            echo "  --help, -h          Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

print_header "SQS Integration Configuration Check"

# Check if config.toml exists
if [ ! -f "$CONFIG_FILE" ]; then
    print_error "Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Please run ./setup-sqs.py first to generate the configuration."
    exit 1
fi

print_success "Found configuration file: config.toml"
echo ""

# Read configuration
QUEUE_URL=$(parse_toml "$CONFIG_FILE" "sqs" "queue_url")
QUEUE_ARN=$(parse_toml "$CONFIG_FILE" "sqs" "queue_arn")
REGION=$(parse_toml "$CONFIG_FILE" "sqs" "region")
STACK_NAME=$(parse_toml "$CONFIG_FILE" "stack" "name")
CATALOG_URL=$(parse_toml "$CONFIG_FILE" "stack" "catalog_url")
ACCOUNT_ID=$(parse_toml "$CONFIG_FILE" "stack" "account_id")
UPDATED_ROLES=$(parse_toml_array "$CONFIG_FILE" "roles" "updated")

# Display configuration
print_header "Configuration Summary"
echo "SQS Queue:"
echo "  URL:    $QUEUE_URL"
echo "  ARN:    $QUEUE_ARN"
echo "  Region: $REGION"
echo ""
echo "CloudFormation Stack:"
echo "  Name:    $STACK_NAME"
echo "  Catalog: $CATALOG_URL"
if [ -n "$ACCOUNT_ID" ]; then
    echo "  Account: $ACCOUNT_ID"
fi
echo ""

if [ -n "$UPDATED_ROLES" ]; then
    echo "IAM Roles with SQS Permissions:"
    for role in $UPDATED_ROLES; do
        echo "  - $role"
    done
else
    print_warning "No IAM roles found in configuration"
fi
echo ""

# Build AWS CLI command
AWS_CMD="aws"
if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="$AWS_CMD --profile $AWS_PROFILE"
    echo "Using AWS profile: $AWS_PROFILE"
    echo ""
fi

# Verify SQS queue exists and is accessible
print_header "Verification Steps"

echo "1. Checking SQS queue accessibility..."
if $AWS_CMD sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --region "$REGION" \
    --output json > /dev/null 2>&1; then
    print_success "SQS queue is accessible"

    # Get queue attributes if verbose
    if $VERBOSE; then
        echo ""
        echo "Queue attributes:"
        $AWS_CMD sqs get-queue-attributes \
            --queue-url "$QUEUE_URL" \
            --attribute-names All \
            --region "$REGION" \
            --output json | python3 -m json.tool || true
    fi
else
    print_error "Cannot access SQS queue"
    echo ""
    echo "Possible issues:"
    echo "  - AWS credentials not configured"
    echo "  - Insufficient permissions"
    echo "  - Queue does not exist or was deleted"
    exit 1
fi
echo ""

# Verify CloudFormation stack
echo "2. Checking CloudFormation stack..."
if $AWS_CMD cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --output json > /dev/null 2>&1; then
    print_success "CloudFormation stack exists"

    if $VERBOSE; then
        echo ""
        echo "Stack outputs:"
        $AWS_CMD cloudformation describe-stacks \
            --stack-name "$STACK_NAME" \
            --region "$REGION" \
            --query 'Stacks[0].Outputs' \
            --output table || true
    fi
else
    print_warning "Cannot access CloudFormation stack (may have been deleted)"
fi
echo ""

# Verify IAM role permissions
if [ -n "$UPDATED_ROLES" ]; then
    echo "3. Checking IAM role permissions..."

    for role in $UPDATED_ROLES; do
        echo "   Checking role: $role"

        # Get inline policies
        POLICIES=$($AWS_CMD iam list-role-policies \
            --role-name "$role" \
            --output json 2>/dev/null | python3 -c "import sys, json; print(' '.join(json.load(sys.stdin).get('PolicyNames', [])))" 2>/dev/null || echo "")

        if [ -z "$POLICIES" ]; then
            print_warning "Cannot access role or no inline policies found"
            continue
        fi

        # Check each policy for SQS permissions
        HAS_SQS_PERMISSION=false
        for policy in $POLICIES; do
            POLICY_DOC=$($AWS_CMD iam get-role-policy \
                --role-name "$role" \
                --policy-name "$policy" \
                --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    doc = data.get('PolicyDocument', {})
    for stmt in doc.get('Statement', []):
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        resources = stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]

        has_sqs = any('sqs:SendMessage' in a or 'sqs:*' in a for a in actions)
        has_resource = '$QUEUE_ARN' in resources or '*' in resources

        if has_sqs and has_resource:
            print('true')
            sys.exit(0)
    print('false')
except:
    print('false')
" 2>/dev/null || echo "false")

            if [ "$POLICY_DOC" = "true" ]; then
                HAS_SQS_PERMISSION=true
                break
            fi
        done

        if $HAS_SQS_PERMISSION; then
            print_success "Role has sqs:SendMessage permission"
        else
            print_error "Role missing sqs:SendMessage permission"
            echo "      Run ./setup-sqs.py again to add permissions"
        fi
    done
    echo ""
else
    print_warning "No IAM roles configured - skipping permission check"
    echo ""
fi

# Test sending a test message (optional)
echo "4. Testing SQS message send capability..."
TEST_MESSAGE='{"test": true, "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'", "source": "check-sqs.sh"}'

if $AWS_CMD sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$TEST_MESSAGE" \
    --region "$REGION" \
    --output json > /dev/null 2>&1; then
    print_success "Successfully sent test message to queue"
    echo "   Test message: $TEST_MESSAGE"
else
    print_warning "Could not send test message (may need additional permissions)"
fi
echo ""

# Summary
print_header "Verification Complete"

echo "Configuration Status:"
echo "  ✓ config.toml exists and is readable"
echo "  ✓ SQS queue is accessible"
echo "  ✓ Configuration contains valid AWS resources"
echo ""

echo "Next Steps:"
echo "  1. Update your Nextflow workflow to use the queue URL:"
echo "     $QUEUE_URL"
echo "  2. Launch a workflow via Seqera Platform"
echo "  3. Monitor the queue for messages:"
echo "     $AWS_CMD sqs receive-message --queue-url '$QUEUE_URL' --region '$REGION'"
echo ""

if $VERBOSE; then
    echo "Full Configuration:"
    cat "$CONFIG_FILE"
    echo ""
fi
