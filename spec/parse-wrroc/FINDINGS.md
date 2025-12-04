# WRROC Timing Investigation - Findings

## Executive Summary

**Answer: onComplete runs BEFORE nf-prov writes the WRROC file.**

The nf-prov plugin writes the WRROC file during plugin shutdown, which occurs AFTER all `workflow.onComplete` handlers have finished executing. This means it is **impossible** for `onComplete` to wait for the WRROC file within the handler itself.

## Timeline Evidence

From test run on 2025-12-02:

```
12:16:39 - workflow.onComplete handler starts
12:16:39 - WRROC verification begins (waits up to 60 seconds)
12:17:40 - WRROC verification times out (file not found)
12:17:40 - SQS message attempted (fails due to permissions, but that's separate)
12:17:41 - onComplete handler fails and exits
12:17:41 - nf-prov plugin shutdown begins
12:17:41 - WRROC file written (ro-crate-metadata.json created)
12:17:41 - nf-prov plugin stopped
```

## Key Insights

1. **Plugin Lifecycle**: nf-prov writes the WRROC file during plugin shutdown, not during workflow execution
2. **Ordering**: The sequence is: workflow completes → onComplete runs → plugins stop → WRROC written
3. **No Solution in onComplete**: No amount of waiting in `onComplete` will allow it to see the WRROC file
4. **File Eventually Exists**: The WRROC file IS created successfully, just after onComplete finishes

## Implications for SQS/Quilt Integration

### Current Behavior
- SQS message is sent with `source_prefix: "results/"`
- WRROC file doesn't exist yet when message is sent
- WRROC file gets created ~1 second after SQS message is sent
- Quilt packager may or may not see the WRROC file depending on timing

### Risk Assessment
- **Low Risk**: If Quilt packager has any delay (network, queue processing, etc.), the file will likely exist by the time it reads the directory
- **Medium Risk**: If Quilt packager is very fast, it might miss the WRROC file
- **High Value**: The WRROC file provides valuable provenance metadata if included

## Implementation Decision

Given these findings, we've implemented a **warn-and-proceed** approach:

1. Wait up to 60 seconds for WRROC file (defensive, though futile)
2. If not found, log clear warning
3. Proceed with SQS notification anyway
4. Warning is visible in logs for debugging

### Why This Approach

1. **Non-blocking**: Doesn't fail the workflow
2. **Visible**: Clear logging when file is missing
3. **Defensive**: Handles edge cases if plugin behavior changes
4. **Realistic**: File will exist seconds after message is sent

## Recommendations

### Short-term (Implemented)
- ✅ Add WRROC file verification with timeout
- ✅ Log warning if file not found
- ✅ Proceed with SQS notification

### Long-term (Future Considerations)
1. **Coordinate with Quilt team**: Ensure packager has slight delay or retry logic
2. **Alternative timing**: Investigate if nf-prov has hooks that run earlier
3. **Post-processing**: Consider separate job that waits for WRROC then sends SQS
4. **Nextflow feature request**: Ask for plugin completion hook that runs after plugins stop

## Test Results

### Test 1: 30-second timeout
- Started: 12:15:29
- Timeout: 12:15:59 (file not found)
- File created: 12:16:00 (+31 seconds from start)

### Test 2: 60-second timeout
- Started: 12:16:39
- Timeout: 12:17:40 (file not found)
- File created: 12:17:41 (+62 seconds from start)

**Conclusion**: Timeout duration doesn't matter - file is created after onComplete exits, not during execution.

## Code Changes

Files modified:
- [main-sqs.nf](../../main-sqs.nf) - Added WRROC verification in workflow.onComplete (lines 119-156)
- Maximum wait time: 60 seconds
- Poll interval: 500ms
- Behavior on timeout: WARN and continue

## References

- nf-prov plugin: https://github.com/nextflow-io/nf-prov
- WRROC specification: https://www.researchobject.org/workflow-run-crate/
- Quilt packaging docs: https://docs.quilt.bio/quilt-platform-catalog-user/packaging
