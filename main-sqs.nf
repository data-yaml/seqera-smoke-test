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

    // Step 3: Send SQS message
    println('Sending SQS message...')
    List<String> cmd = [
        awsCmd, 'sqs', 'send-message',
        '--queue-url', queueUrl,
        '--region', region,
        '--message-body', outdir
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
        println('AWS SQS Response:')
        println(response)
        println(separator)
    }
}
