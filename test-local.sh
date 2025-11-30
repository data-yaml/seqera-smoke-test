#!/bin/bash
set -e

echo "========================================"
echo "Seqera Platform Smoke Test - Local Run"
echo "========================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v nextflow &> /dev/null; then
    echo "ERROR: nextflow not found. Please install Nextflow first."
    exit 1
fi

echo "✓ Nextflow version: $(nextflow -version | head -n1)"

if ! command -v aws &> /dev/null; then
    echo "WARNING: aws CLI not found. SQS notification will fail."
else
    echo "✓ AWS CLI found"
fi

echo ""

# Clean previous results
if [ -d "results" ]; then
    echo "Cleaning previous results..."
    rm -rf results
fi

# Run the workflow
echo "Running workflow locally with Docker..."
echo ""

nextflow run main.nf -profile docker --outdir results

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo ""

# Verify outputs
if [ -f "results/test.txt" ]; then
    echo "✓ Output file created: results/test.txt"
    echo "  Content: $(cat results/test.txt)"
else
    echo "✗ ERROR: Output file not found at results/test.txt"
    exit 1
fi

echo ""
echo "========================================"
echo "Local smoke test PASSED!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Push this workflow to GitHub"
echo "2. Configure Seqera Platform with your AWS Batch compute environment"
echo "3. Run via Seqera Platform CLI or UI"
echo ""
