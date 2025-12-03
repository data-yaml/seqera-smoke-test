#!/usr/bin/env nextflow
/* groovylint-disable-next-line CompileStatic */
nextflow.enable.dsl = 2

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

// Helper method to check if AWS CLI is available
void checkAwsCliAvailability(String awsCmd, String encoding, int exitSuccess, String emptyLine, String separator) {
    println('Checking AWS CLI availability...')
    Process awsCheck = [awsCmd, '--version'].execute()
    awsCheck.waitFor()
    if (awsCheck.exitValue() != exitSuccess) {
        println(emptyLine)
        println(separator)
        println('ERROR: AWS CLI Not Available')
        println(separator)
        println('The AWS CLI is not installed or not in PATH in this compute environment.')
        println(emptyLine)
        println('Required: AWS CLI must be installed in the compute environment container/AMI')
        println(emptyLine)
        println('This workflow will now FAIL due to missing AWS CLI.')
        println(separator)
        throw new IllegalStateException('AWS CLI not available in compute environment')
    }
    String awsVersion = awsCheck.inputStream.getText(encoding).trim()
    println("✓ AWS CLI found: ${awsVersion}")
    println(emptyLine)
}

// Helper method to check AWS credentials
void checkAwsCredentials(String awsCmd, String encoding, int exitSuccess, String emptyLine, String separator, String errorDetailsMsg) {
    println('Checking AWS credentials...')
    Process credsCheck = [awsCmd, 'sts', 'get-caller-identity'].execute()
    credsCheck.waitFor()
    if (credsCheck.exitValue() != exitSuccess) {
        println(emptyLine)
        println(separator)
        println('ERROR: AWS Credentials Not Configured')
        println(separator)
        println('AWS credentials are not available in this compute environment.')
        println(emptyLine)
        println(errorDetailsMsg)
        println(credsCheck.errorStream.getText(encoding))
        println(emptyLine)
        println('Required: Compute environment must have:')
        println('  - IAM instance role (for AWS Batch/EC2), OR')
        println('  - AWS credentials configured in environment')
        println(emptyLine)
        println('This workflow will now FAIL due to missing credentials.')
        println(separator)
        throw new IllegalStateException('AWS credentials not configured in compute environment')
    }
    String identity = credsCheck.inputStream.getText(encoding).trim()
    println('✓ AWS credentials found')
    println("Identity: ${identity}")
    println(emptyLine)
}

// Helper method to check if file exists (supports both local and S3 paths)
boolean fileExists(String path, String awsCmd, String encoding) {
    if (path.startsWith('s3://')) {
        // Use AWS CLI to check S3 file
        Process p = [awsCmd, 's3', 'ls', path].execute()
        p.waitFor()
        return p.exitValue() == 0
    } else {
        // Check local file
        File f = new File(path)
        return f.exists() && f.length() > 0
    }
}

// Helper method to get file size (supports both local and S3 paths)
long getFileSize(String path, String awsCmd, String encoding) {
    if (path.startsWith('s3://')) {
        // Use AWS CLI to get S3 file size
        Process p = [awsCmd, 's3', 'ls', path].execute()
        p.waitFor()
        if (p.exitValue() == 0) {
            String output = p.inputStream.getText(encoding)
            // Parse output like: "2024-12-02 15:30:00      11114 ro-crate-metadata.json"
            def parts = output.trim().split(/\s+/)
            if (parts.length >= 3) {
                return parts[2] as long
            }
        }
        return 0
    } else {
        File f = new File(path)
        return f.length()
    }
}

// Helper method to wait for and verify WRROC file
boolean waitForWrrocFile(String wrrocPath, int maxWaitSeconds, int checkIntervalMs,
                        String awsCmd, String encoding, String emptyLine, String separator) {
    println('Waiting for WRROC file to be written by nf-prov plugin...')
    println("Target path: ${wrrocPath}")
    println("Path type: ${wrrocPath.startsWith('s3://') ? 'S3' : 'Local'}")

    int attempts = (maxWaitSeconds * 1000) / checkIntervalMs
    boolean wrrocFound = false

    for (int i = 0; i < attempts; i++) {
        if (fileExists(wrrocPath, awsCmd, encoding)) {
            long fileSize = getFileSize(wrrocPath, awsCmd, encoding)
            println("✓ WRROC file found: ${wrrocPath}")
            println("  File size: ${fileSize} bytes")
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

    return wrrocFound
}

// Helper method to extract WRROC metadata from file
Map<String, Object> extractWrrocMetadata(File wrrocFile, String emptyLine) {
    Map<String, Object> wrrocMetadata = [:]
    println('Extracting WRROC metadata...')

    try {
        String idKey = '@id'
        String typeKey = '@type'
        String graphKey = '@graph'

        Object wrrocJson = new groovy.json.JsonSlurper().parse(wrrocFile)
        List<Map<String, Object>> graph = wrrocJson[graphKey] as List<Map<String, Object>>

        // Find the root dataset
        Map<String, Object> rootDataset = graph.find { entry -> entry[idKey] == './' }
        if (rootDataset) {
            wrrocMetadata['wrroc_name'] = rootDataset.name
            wrrocMetadata['wrroc_date_published'] = rootDataset.datePublished
            wrrocMetadata['wrroc_license'] = rootDataset.license

            // Find author details
            String authorId = rootDataset.author?[idKey] as String
            if (authorId) {
                Map<String, Object> author = graph.find { entry -> entry[idKey] == authorId }
                if (author) {
                    wrrocMetadata['wrroc_author_name'] = author.name
                    wrrocMetadata['wrroc_author_orcid'] = authorId
                }
            }
        }

        // Find the workflow run action
        Map<String, Object> workflowRun = graph.find { entry -> entry[typeKey] == 'CreateAction' && entry.name?.startsWith('Nextflow workflow run') }
        if (workflowRun) {
            wrrocMetadata['wrroc_run_id'] = workflowRun[idKey]?.replaceAll('^#', '')
            wrrocMetadata['wrroc_start_time'] = workflowRun.startTime
            wrrocMetadata['wrroc_end_time'] = workflowRun.endTime
        }

        // Find the main workflow file
        Map<String, Object> mainWorkflow = graph.find { entry -> entry[idKey] == 'main-sqs.nf' }
        if (mainWorkflow) {
            wrrocMetadata['wrroc_runtime_platform'] = mainWorkflow.runtimePlatform
            wrrocMetadata['wrroc_programming_language'] = mainWorkflow.programmingLanguage?[idKey]
        }

        println("✓ Extracted ${wrrocMetadata.size()} WRROC metadata fields")
        wrrocMetadata.each { key, value ->
            println("  ${key}: ${value}")
        }
    } catch (Exception e) {
        println("⚠ Warning: Failed to parse WRROC file: ${e.message}")
        println('  Continuing without WRROC metadata')
    }
    println(emptyLine)

    return wrrocMetadata
}

// Helper method to build SQS message body
Map<String, Object> buildSqsMessageBody(String outdir, Map<String, Object> wrrocMetadata) {
    Map<String, Object> metadata = [
        nextflow_version: workflow.nextflow.version.toString(),
        workflow_name: workflow.scriptName,
        workflow_id: workflow.runName,
        session_id: workflow.sessionId,
        container: workflow.container ?: 'none',
        success: workflow.success,
        timestamp: new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    ]

    // Add WRROC metadata if available
    if (wrrocMetadata) {
        metadata.putAll(wrrocMetadata)
    }

    return [
        source_prefix: "${outdir}/",
        metadata: metadata,
        commit_message: "Seqera Platform smoke test completed at ${new Date().format('yyyy-MM-dd HH:mm:ss')}"
    ]
}

// Helper method to send SQS message
void sendSqsMessage(String queueUrl, String region, String outdir, String messageJson, String awsCmd,
                    String encoding, int exitSuccess, String emptyLine, String separator, String errorDetailsMsg) {
    println('Sending SQS message...')
    println('Message body:')
    println(messageJson)
    println(emptyLine)

    List<String> cmd = [
        awsCmd, 'sqs', 'send-message',
        '--queue-url', queueUrl,
        '--region', region,
        '--message-body', messageJson
    ]
    Process p = cmd.execute()
    p.waitFor()

    if (p.exitValue() != exitSuccess) {
        handleSqsSendError(p, queueUrl, region, outdir, encoding, emptyLine, separator, errorDetailsMsg)
    } else {
        handleSqsSendSuccess(p, queueUrl, region, outdir, messageJson, encoding, emptyLine, separator)
    }
}

// Helper method to handle SQS send error
void handleSqsSendError(Process p, String queueUrl, String region, String outdir,
                        String encoding, String emptyLine, String separator, String errorDetailsMsg) {
    String errorText = p.errorStream.getText(encoding)
    String stdoutText = p.inputStream.getText(encoding)

    println(emptyLine)
    println(separator)
    println('ERROR: SQS Message Send Failed')
    println(separator)
    println("Exit Code: ${p.exitValue()}")
    println("Queue URL: ${queueUrl}")
    println("Region: ${region}")
    println("Output folder: ${outdir}")
    println(emptyLine)
    println('=== AWS CLI STDERR ===')
    println(errorText.empty ? '(empty)' : errorText)
    println(emptyLine)
    println('=== AWS CLI STDOUT ===')
    println(stdoutText.empty ? '(empty)' : stdoutText)
    println(emptyLine)
    println(errorDetailsMsg)
    println(errorText)
    println(emptyLine)
    println('Common causes:')

    if (errorText.contains('NonExistentQueue')) {
        println('  - Queue does not exist or URL is incorrect')
        println("  - Check queue URL: ${queueUrl}")
    } else if (errorText.contains('AccessDenied') || errorText.contains('not authorized')) {
        println('  - Missing IAM permission: sqs:SendMessage')
        println('  - The compute environment\'s IAM role must have this permission')
    } else if (errorText.contains('InvalidClientTokenId')) {
        println('  - AWS credentials are invalid or expired')
    } else {
        println('  - Check queue URL and IAM permissions')
    }

    println(emptyLine)
    println('Required IAM permission on compute environment role:')
    println("  - sqs:SendMessage for queue: ${queueUrl}")
    println(emptyLine)
    println('This workflow will now FAIL due to SQS send error.')
    println(separator)
    throw new IllegalStateException("SQS message send failed: ${errorText}")
}

// Helper method to handle SQS send success
void handleSqsSendSuccess(Process p, String queueUrl, String region, String outdir,
                          String messageJson, String encoding, String emptyLine, String separator) {
    String response = p.inputStream.getText(encoding)
    println(separator)
    println('✓✓✓ SQS Integration SUCCESS ✓✓✓')
    println(separator)
    println('Message sent successfully to queue!')
    println(emptyLine)
    println("Queue URL: ${queueUrl}")
    println("Region: ${region}")
    println("Output folder: ${outdir}")
    println(emptyLine)
    println('Message Content (Quilt Packaging Request):')
    println(messageJson)
    println(emptyLine)
    println('AWS SQS Response:')
    println(response)
    println(separator)
}

workflow.onComplete {
    /* groovylint-disable-next-line DuplicateNumberLiteral */
    final int exitSuccess = 0

    // Configuration
    String outdir = params.outdir
    String queueUrl = 'https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA'
    String region = 'us-east-1'
    String emptyLine = ''
    String separator = '========================================'
    String encoding = 'UTF-8'
    String awsCmd = 'aws'
    String errorDetailsMsg = 'Error details:'

    // Print header
    println(emptyLine)
    println(separator)
    println('SQS Integration - Starting')
    println(separator)
    println("Queue URL: ${queueUrl}")
    println("Region: ${region}")
    println("Output folder: ${outdir}")
    println("Workflow status: ${workflow.success ? 'SUCCESS' : 'FAILED'}")
    println(emptyLine)

    // Check if workflow succeeded - only send SQS notification for successful runs
    if (!workflow.success) {
        println('Workflow failed - skipping SQS notification')
        println("Error report: ${workflow.errorReport}")
        println(separator)
        return
    }

    // Step 1: Check AWS CLI availability
    checkAwsCliAvailability(awsCmd, encoding, exitSuccess, emptyLine, separator)

    // Step 2: Check AWS credentials
    checkAwsCredentials(awsCmd, encoding, exitSuccess, emptyLine, separator, errorDetailsMsg)

    // Step 3: Wait for WRROC file (nf-prov output)
    String wrrocPath = "${outdir}/ro-crate-metadata.json"
    int maxWaitSeconds = 60
    int checkIntervalMs = 500
    boolean wrrocFound = waitForWrrocFile(wrrocPath, maxWaitSeconds, checkIntervalMs, awsCmd, encoding, emptyLine, separator)

    // Step 4: Extract WRROC metadata
    Map<String, Object> wrrocMetadata = [:]
    if (wrrocFound) {
        File wrrocFile = new File(wrrocPath)
        wrrocMetadata = extractWrrocMetadata(wrrocFile, emptyLine)
    }

    // Step 5: Build and send SQS message
    Map<String, Object> messageBody = buildSqsMessageBody(outdir, wrrocMetadata)
    String messageJson = groovy.json.JsonOutput.toJson(messageBody)

    sendSqsMessage(queueUrl, region, outdir, messageJson, awsCmd, encoding, exitSuccess, emptyLine, separator, errorDetailsMsg)
}
