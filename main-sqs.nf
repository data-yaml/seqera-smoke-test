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

workflow.onComplete {
    /* groovylint-disable-next-line DuplicateNumberLiteral */
    final int exitSuccess = 0

    String outdir = params.outdir
    String queueUrl = 'https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA'
    String region = 'us-east-1'
    String emptyLine = ''
    String separator = '========================================'
    String encoding = 'UTF-8'
    String awsCmd = 'aws'
    String errorDetailsMsg = 'Error details:'

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

    // Step 1: Check if AWS CLI is available
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

    // Step 2: Check AWS credentials
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

    // Step 3: Wait for WRROC file (nf-prov output)
    println('Waiting for WRROC file to be written by nf-prov plugin...')
    String wrrocPath = "${outdir}/ro-crate-metadata.json"
    File wrrocFile = new File(wrrocPath)

    int maxWaitSeconds = 60
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

    // Step 4: Extract WRROC metadata
    Map<String, Object> wrrocMetadata = [:]
    if (wrrocFound) {
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
    }

    // Step 5: Send SQS message
    println('Sending SQS message...')

    // Construct Quilt packaging message body according to:
    // https://docs.quilt.bio/quilt-platform-catalog-user/packaging
    // Only source_prefix is required; registry and package_name are inferred from it
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

    Map<String, Object> messageBody = [
        source_prefix: "${outdir}/",  // trailing '/' for folder; registry & package inferred from this
        metadata: metadata,
        commit_message: "Seqera Platform smoke test completed at ${new Date().format('yyyy-MM-dd HH:mm:ss')}"
    ]

    String messageJson = groovy.json.JsonOutput.toJson(messageBody)

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
        // FAIL THE WORKFLOW - SQS is a critical requirement
        throw new IllegalStateException("SQS message send failed: ${errorText}")
    } else {
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
}
