# SQS Integration Test Script - Technical Specification

## Overview

Create a new test script variant (`test-sqs.sh`) that integrates SQS packaging events into the Seqera Platform workflow test suite. The script will validate SQS permissions upfront, launch workflows with SQS integration enabled, wait for completion, and verify message delivery.

## Assumptions and Constraints

### Critical Assumption: Nextflow Workflow Handler Placement

**Assumption**: `workflow.onComplete` handlers MUST be defined in the main workflow script (`.nf` file), NOT in config files loaded with `-c` flag.

**Rationale**:
- Config files loaded with `-c` are for settings and parameters, not executable code
- Workflow event handlers (onComplete, onError) are code execution logic
- While Nextflow documentation suggests handlers can be in config files, practical experience shows this causes errors
- The existing `sqs.config` file failed when used with `-c` flag for this reason

**Solution**: Create a new workflow file `main-sqs.nf` that includes both:
1. The workflow logic from `main.nf`
2. The `workflow.onComplete` SQS hook

### User Requirements Confirmed

1. **SQS Queue URL**: Hardcoded as `https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA`
2. **Script Approach**: New script that reuses functions from test-tw.sh via shared library
3. **Config Integration**: ~~Use existing sqs.config via `-c` flag~~ **CORRECTED**: Create main-sqs.nf with embedded workflow.onComplete
4. **Verification**: Maximum verification without adding risk - check permissions upfront, verify message delivery
5. **Error Handling**: Better error messages, hard fail on any issues

## Implementation Approach

### Phase 1: Extract Shared Library

**File**: `lib/tw-common.sh`

Create a bash library to house reusable functions from test-tw.sh:

**Functions to Extract**:
- `check_tw_cli()` - Check if tw CLI is installed
- `check_tw_login()` - Verify logged in to Seqera Platform
- `check_aws_cli()` - Check if AWS CLI is available (NEW)
- `load_env_file()` - Load .env variables
- `save_to_env()` - Save key=value to .env
- `ensure_gitignore()` - Ensure .env is in .gitignore
- `get_or_prompt_token()` - Get/prompt for TOWER_ACCESS_TOKEN
- `get_or_prompt_workspace()` - Get/prompt for workspace
- `get_or_prompt_compute_env()` - Get/prompt for compute environment
- `get_or_prompt_s3_bucket()` - Get/prompt for S3 bucket
- `detect_git_branch()` - Detect current git branch
- `write_params_file()` - Write params.yaml
- `print_header()` - Print section headers

**Global Variables**:
```bash
YES_FLAG=${YES_FLAG:-false}
ENV_FILE=${ENV_FILE:-.env}
```

### Phase 2: Refactor test-tw.sh

Modify existing script to use shared library while maintaining exact same behavior:

1. Add sourcing of lib/tw-common.sh at the top
2. Replace inline implementations with function calls
3. Keep script-specific logic (main flow, tw launch command)
4. Ensure backward compatibility (no behavior changes)

**Success Criteria**: `./test-tw.sh` and `./test-tw.sh --yes` work identically to before

### Phase 3: Create main-sqs.nf

**File**: `main-sqs.nf`

Create a new Nextflow workflow script that combines:

1. **Workflow Logic** (from main.nf):
   ```groovy
   #!/usr/bin/env nextflow
   nextflow.enable.dsl=2

   process tiny_test {
       publishDir params.outdir, mode: 'copy'

       output:
       path 'test.txt'
       path 'system-info.txt'

       script:
       """
       echo 'Hello from Seqera Platform smoke test' > test.txt
       echo 'Test completed successfully at:' >> test.txt
       date >> test.txt

       echo 'System Information' > system-info.txt
       echo '==================' >> system-info.txt
       echo '' >> system-info.txt
       echo 'Hostname:' >> system-info.txt
       hostname >> system-info.txt
       echo '' >> system-info.txt
       echo 'Date:' >> system-info.txt
       date >> system-info.txt
       echo '' >> system-info.txt
       echo 'Working Directory:' >> system-info.txt
       pwd >> system-info.txt
       echo '' >> system-info.txt
       echo 'Disk Space:' >> system-info.txt
       df -h . >> system-info.txt
       """
   }

   workflow {
       tiny_test()
       tiny_test.out[0].view { file -> "Generated output: ${file}" }
   }
   ```

2. **SQS Hook** (from sqs.config, adapted):
   ```groovy
   workflow.onComplete {
       def outdir = params.outdir.toString()
       def queueUrl = "https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA"

       println "Sending SQS message for output folder: ${outdir}"

       def cmd = [
           'aws','sqs','send-message',
           '--queue-url', queueUrl,
           '--message-body', outdir
       ]

       def p = cmd.execute()
       p.waitFor()

       if( p.exitValue() != 0 ) {
           println "SQS send error:"
           println p.err.text
       } else {
           println "SQS send success:"
           println p.in.text
       }
   }
   ```

**Note**: This approach duplicates some workflow logic but is necessary because workflow handlers must be in the main script file.

### Phase 4: Create test-sqs.sh

**File**: `test-sqs.sh`

New script with enhanced functionality:

**Structure**:
```bash
#!/bin/bash
set -e

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA"
QUEUE_REGION="us-east-1"

# Source common library
source "$LIB_DIR/tw-common.sh"

# Parse arguments
# ... (similar to test-tw.sh)

# Main flow
main() {
    print_header "Seqera Platform Smoke Test - SQS Integration"

    # Prerequisites (AWS CLI is REQUIRED, not optional)
    check_tw_cli
    check_tw_login
    check_aws_cli

    # SQS validation before launch
    validate_sqs_permissions

    # Configuration (reuses common functions)
    get_or_prompt_token
    get_or_prompt_workspace
    get_or_prompt_compute_env
    get_or_prompt_s3_bucket

    CURRENT_BRANCH=$(detect_git_branch)

    # Display config with SQS info
    print_config_summary_with_sqs

    # Launch workflow using main-sqs.nf
    launch_workflow_sqs

    # Wait and verify
    wait_for_workflow_completion
    verify_sqs_message

    # Success message
    display_sqs_verification_results
}

main
```

**Key Functions**:

1. **validate_sqs_permissions()**: Upfront validation
   - Check queue exists: `aws sqs get-queue-attributes`
   - Test send permission: Send a test message
   - Test receive permission: Try receiving messages
   - Clear error messages for each failure

2. **launch_workflow_sqs()**: Modified launch command
   ```bash
   tw launch https://github.com/data-yaml/seqera-smoke-test \
     --workspace="$WORKSPACE" \
     --revision="$CURRENT_BRANCH" \
     --compute-env="$COMPUTE_ENV" \
     --profile awsbatch \
     --params-file "$PARAMS_FILE" \
     --main-script main-sqs.nf
   ```
   Note: Uses `--main-script main-sqs.nf` to point to SQS-enabled workflow

3. **wait_for_workflow_completion()**: Poll workflow status
   - Check every 60 seconds
   - Max wait: 10 minutes (600 seconds)
   - Use `tw runs view -i $RUN_ID --workspace="$WORKSPACE"`
   - Watch for status: SUCCEEDED, FAILED, CANCELLED, RUNNING

4. **verify_sqs_message()**: Check message delivery
   - Wait 5 seconds after workflow completion
   - Receive messages: `aws sqs receive-message --max-number-of-messages 10`
   - Search for message containing output directory path
   - Display message body if found
   - Error if not found with troubleshooting steps

### Phase 5: Update Documentation

**File**: `README.md`

**Changes**:

1. **QuickStart section** (lines 14-23):
   ```markdown
   ## QuickStart

   If everything is setup:

   ```bash
   ./test-local.sh           # Test locally with Docker
   ./test-tw.sh              # Interactive mode - prompts for configuration
   ./test-tw.sh --yes        # Automated mode - uses saved configuration
   ./test-sqs.sh          # Interactive mode WITH SQS integration
   ./test-sqs.sh --yes    # Automated mode WITH SQS integration
   ```
   ```

2. **New section after "Usage"**: Add "Run with SQS Integration" section
   - Prerequisites (AWS CLI, SQS permissions)
   - Interactive mode usage
   - Automated mode usage
   - What's different from test-tw.sh
   - Configuration details

3. **Files section** (line 182): Update file list
   ```markdown
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
   ```

## Key Technical Decisions

1. **Library Pattern**: Bash source-able library for code reuse
2. **Implementation Language**: Bash (consistent with existing scripts, adequate for the complexity level)
3. **SQS Queue URL**: Hardcoded as `https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA`
4. **Workflow Integration**: Create main-sqs.nf with embedded workflow.onComplete (handlers must be in main script, not config files)
5. **Main Script**: Use `--main-script main-sqs.nf` in tw launch command
6. **Polling Strategy**: 60-second intervals, 10-minute timeout
7. **Message Verification**: Search last 10 messages for matching output directory
8. **Error Strategy**: Fail fast with clear error messages at each validation point

## Critical Files

1. **lib/tw-common.sh** (NEW) - Shared function library
2. **main-sqs.nf** (NEW) - Workflow script with embedded workflow.onComplete SQS hook
3. **test-sqs.sh** (NEW) - SQS integration test script
4. **test-tw.sh** (MODIFY) - Refactor to use shared library
5. **README.md** (MODIFY) - Document new functionality

## Success Criteria

- test-tw.sh maintains exact same behavior after refactoring
- test-sqs.sh successfully validates SQS permissions before launch
- Script launches workflow using main-sqs.nf with SQS hook
- Script waits for workflow completion and verifies SQS message
- Clear error messages at each failure point
- Documentation updated with usage examples
- All changes committed, tested, and PR created

## Error Handling Scenarios

### 1. AWS CLI Not Found
```
ERROR: AWS CLI not found but required for SQS integration.

Installation:
  macOS:     brew install awscli
  Linux:     https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
```

### 2. AWS Credentials Not Configured
```
ERROR: AWS credentials not configured.

Please configure AWS credentials:
  aws configure

Or set environment variables:
  export AWS_ACCESS_KEY_ID=...
  export AWS_SECRET_ACCESS_KEY=...
```

### 3. SQS Queue Inaccessible
```
ERROR: Cannot access SQS queue.

Possible causes:
  1. Queue does not exist
  2. Incorrect queue URL: https://sqs.us-east-1.amazonaws.com/...
  3. Missing IAM permissions for sqs:GetQueueAttributes
  4. Wrong AWS region selected (queue is in us-east-1)

Required IAM permissions:
  - sqs:GetQueueAttributes
  - sqs:SendMessage
  - sqs:ReceiveMessage
```

### 4. Workflow Failure
```
ERROR: Workflow failed with status: FAILED

View details:
  tw runs view -i 5aBcDeF1234567 --workspace='Organization/Workspace'
```

### 5. SQS Message Not Found
```
ERROR: No SQS message found for output directory: s3://bucket/path

Possible causes:
  1. workflow.onComplete hook failed to send message
  2. Message sent to different queue
  3. Message already consumed by another process

Check workflow logs:
  tw runs view -i 5aBcDeF1234567 --workspace='Organization/Workspace'
```

## Testing Strategy

### Development Testing
1. Create a test SQS queue for development
2. Temporarily override `SQS_QUEUE_URL` in script
3. Run through full workflow
4. Verify message delivery
5. Clean up test queue

### Integration Testing Scenarios
1. **First-time setup**: Clean slate, interactive mode
2. **Automated mode**: Use saved configuration
3. **Error handling**: No AWS CLI, no permissions, workflow failure
4. **Concurrent runs**: Multiple runs with different output paths

### CI/CD Testing
- GitHub Actions workflow to test automated mode
- Use repository secrets for credentials
- Test on push to main and PR branches

## Implementation Sequence

1. **Phase 1**: Create lib/tw-common.sh with extracted functions (low risk)
2. **Phase 2**: Refactor test-tw.sh to use library (medium risk, test thoroughly)
3. **Phase 3**: Create main-sqs.nf with embedded SQS hook (high value)
4. **Phase 4**: Create test-sqs.sh with validation and verification (complex)
5. **Phase 5**: Update README.md with documentation

## Known Limitations

1. **Code Duplication**: main-sqs.nf duplicates logic from main.nf because workflow handlers must be in the main script
2. **Message Consumption**: If packager service consumes messages quickly, verification may not find the message
3. **Polling Timeout**: 30-minute timeout may not be sufficient for complex workflows
4. **Queue Hardcoding**: Queue URL is hardcoded; changing it requires modifying both main-sqs.nf and test-sqs.sh

## Future Enhancements

1. Make queue URL configurable via environment variable
2. Add support for multiple queue regions
3. Implement message attributes for better filtering
4. Add dry-run mode for testing without actual SQS sends
5. Consider moving to Nextflow trace observers plugin (when stable)
