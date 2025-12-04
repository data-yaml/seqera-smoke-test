# WRROC File Verification Plan

## Problem Statement

The `workflow.onComplete` handler in `main-sqs.nf` sends an SQS message to trigger Quilt packaging of the output directory. However, there's no guarantee that the nf-prov plugin has finished writing the WRROC file (`ro-crate-metadata.json`) before the SQS message is sent.

If the WRROC file hasn't been written yet, it won't be included in the Quilt package, defeating the purpose of enabling nf-prov provenance tracking.

## Solution Overview

Add defensive verification in the `workflow.onComplete` handler to wait for the WRROC file to exist before sending the SQS message. Use a retry loop with bounded waiting to handle potential race conditions gracefully.

## Implementation Details

### File to Modify
- [main-sqs.nf:40-212](main-sqs.nf#L40-L212) - The `workflow.onComplete` handler

### Insertion Point
After the AWS credential check (line 117) and before the "Sending SQS message..." section (line 120), insert the WRROC verification logic.

### Code to Add

```groovy
// Step 4: Wait for WRROC file (nf-prov output)
println('Waiting for WRROC file to be written by nf-prov plugin...')
String wrrocPath = "${outdir}/ro-crate-metadata.json"
File wrrocFile = new File(wrrocPath)

int maxWaitSeconds = 30
int checkIntervalMs = 500
int attempts = (maxWaitSeconds * 1000) / checkIntervalMs
boolean wrrocFound = false

for (int i = 0; i < attempts; i++) {
    if (wrrocFile.exists() && wrrocFile.length() > 0) {
        println("✓ WRROC file found: ${wrrocPath}")
        println("  File size: ${wrrocFile.length()} bytes")
        wrrocFound = true
        break
    }
    Thread.sleep(checkIntervalMs)
}

if (!wrrocFound) {
    println(emptyLine)
    println(separator)
    println('WARNING: WRROC File Not Found')
    println(separator)
    println("Expected path: ${wrrocPath}")
    println("Waited: ${maxWaitSeconds} seconds")
    println(emptyLine)
    println('The nf-prov plugin should have created this file.')
    println('Possible causes:')
    println('  - nf-prov plugin may not have finished writing yet')
    println('  - Plugin may have failed silently')
    println('  - Configuration issue with nf-prov')
    println(emptyLine)
    println('Proceeding with SQS notification, but WRROC file may be missing from package.')
    println(separator)
}
println(emptyLine)

// Step 5: Send SQS message
println('Sending SQS message...')
```

### Step Numbering Updates
- Current Step 3 (Send SQS message) becomes Step 5
- Update comment on line 119 from "Step 3" to "Step 5"

## Testing Strategy

### Test Case 1: Normal Operation (WRROC file exists)
- Run workflow normally with nf-prov enabled
- Verify WRROC file is found quickly (within first few checks)
- Verify SQS message is sent successfully
- Verify WRROC file is included in Quilt package

### Test Case 2: WRROC File Missing
- Temporarily disable nf-prov in `nextflow.config`
- Run workflow
- Verify warning message appears after 30-second timeout
- Verify SQS message is still sent (workflow doesn't fail)
- Verify logs show clear warning about missing file

### Test Case 3: WRROC File Delayed
- Run workflow and manually observe timing
- Check logs to see how many polling attempts occurred before file was found
- Verify no unnecessary waiting if file exists immediately

## Configuration Parameters

- **Max wait time**: 30 seconds (reasonable for plugin to complete)
- **Poll interval**: 500ms (frequent enough to detect quickly, not too aggressive)
- **File size check**: `wrrocFile.length() > 0` ensures file is not just created but has content
- **Behavior on timeout**: WARN but continue (non-blocking)

## Risk Mitigation

1. **Bounded wait**: 30-second timeout prevents infinite loops
2. **Non-failing**: Warns but doesn't fail workflow on timeout
3. **Visibility**: Clear logging at each step
4. **File size check**: Ensures file has actual content, not just empty placeholder

## Future Considerations

If WRROC files are consistently missing or delayed:
1. Investigate nf-prov plugin timing/lifecycle
2. Consider making timeout configurable via params
3. Consider making failure mode configurable (warn vs fail)
4. Add explicit dependency/ordering if Nextflow provides mechanism
