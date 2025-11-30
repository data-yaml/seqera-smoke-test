#!/usr/bin/env nextflow
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
    String outdir = params.outdir
    String queueUrl = 'https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA'
    String region = 'us-east-1'

    println ''
    println '========================================'
    println 'SQS Integration - Starting'
    println '========================================'
    println "Queue URL: ${queueUrl}"
    println "Region: ${region}"
    println "Output folder: ${outdir}"
    println "Workflow status: ${workflow.success ? 'SUCCESS' : 'FAILED'}"
    println ''

    // Step 1: Check if AWS CLI is available
    println 'Checking AWS CLI availability...'
    def awsCheck = ['aws', '--version'].execute()
    awsCheck.waitFor()

    if (awsCheck.exitValue() != 0) {
        println ""
        println "========================================"
        println "ERROR: AWS CLI Not Available"
        println "========================================"
        println "The AWS CLI is not installed or not in PATH in this compute environment."
        println ""
        println "Required: AWS CLI must be installed in the compute environment container/AMI"
        println ""
        println "This workflow will now FAIL due to missing AWS CLI."
        println "========================================"
        throw new Exception("AWS CLI not available in compute environment")
    }

    String awsVersion = awsCheck.in.text.trim()
    println "✓ AWS CLI found: ${awsVersion}"
    println ''

    // Step 2: Check AWS credentials
    println 'Checking AWS credentials...'
    def credsCheck = ['aws', 'sts', 'get-caller-identity'].execute()
    credsCheck.waitFor()

    if (credsCheck.exitValue() != 0) {
        println ""
        println "========================================"
        println "ERROR: AWS Credentials Not Configured"
        println "========================================"
        println "AWS credentials are not available in this compute environment."
        println ""
        println "Error details:"
        println credsCheck.err.text
        println ""
        println "Required: Compute environment must have:"
        println "  - IAM instance role (for AWS Batch/EC2), OR"
        println "  - AWS credentials configured in environment"
        println ""
        println "This workflow will now FAIL due to missing credentials."
        println "========================================"
        throw new Exception("AWS credentials not configured in compute environment")
    }

    String identity = credsCheck.in.text.trim()
    println '✓ AWS credentials found'
    println "Identity: ${identity}"
    println ''

    // Step 3: Send SQS message
    println 'Sending SQS message...'
    def cmd = [
        'aws', 'sqs', 'send-message',
        '--queue-url', queueUrl,
        '--region', region,
        '--message-body', outdir
    ]

    def p = cmd.execute()
    p.waitFor()

    if (p.exitValue() != 0) {
        String errorText = p.err.text
        println ""
        println "========================================"
        println "ERROR: SQS Message Send Failed"
        println "========================================"
        println "Queue URL: ${queueUrl}"
        println "Region: ${region}"
        println "Output folder: ${outdir}"
        println ""
        println "Error details:"
        println errorText
        println ""
        println "Common causes:"
        if (errorText.contains("NonExistentQueue")) {
            println "  - Queue does not exist or URL is incorrect"
            println "  - Check queue URL: ${queueUrl}"
        } else if (errorText.contains("AccessDenied") || errorText.contains("not authorized")) {
            println "  - Missing IAM permission: sqs:SendMessage"
            println "  - The compute environment's IAM role must have this permission"
        } else if (errorText.contains("InvalidClientTokenId")) {
            println "  - AWS credentials are invalid or expired"
        } else {
            println "  - Check queue URL and IAM permissions"
        }
        println ""
        println "Required IAM permission on compute environment role:"
        println "  - sqs:SendMessage for queue: ${queueUrl}"
        println ""
        println "This workflow will now FAIL due to SQS send error."
        println "========================================"

        // FAIL THE WORKFLOW - SQS is a critical requirement
        throw new Exception("SQS message send failed: ${errorText}")
    } else {
        String response = p.in.text
        println "========================================"
        println "✓✓✓ SQS Integration SUCCESS ✓✓✓"
        println "========================================"
        println "Message sent successfully to queue!"
        println ""
        println "Queue URL: ${queueUrl}"
        println "Region: ${region}"
        println "Output folder: ${outdir}"
        println ""
        println "AWS SQS Response:"
        println response
        println "========================================"
    }
}
