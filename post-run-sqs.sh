#!/bin/bash
# post-run script - downloads and executes Python script from GitHub
set -euo pipefail
echo "===== CWD ========"
cwd
echo "===== Local Files========"
ls root home tmp .nextflow
echo "=== Post-Run Environment ==="
printenv
echo "=== Remote Files ==="
aws s3 ls s3://quilt-demos/scratch/2Z7DVmgqEHM8Zj/
aws s3 ls s3://quilt-demos/results/2Z7DVmgqEHM8Zj/
echo ""
SCRIPT_URL="https://raw.githubusercontent.com/data-yaml/seqera-smoke-test/parse-wrroc/scripts/post_run_sqs.py"
OUTDIR="${TOWER_OUTDIR:-}"
[ -z "$OUTDIR" ] && echo "ERROR: TOWER_OUTDIR not set" && printenv | sort && exit 1
echo "Downloading post-run script from GitHub..."
curl -sSfL "$SCRIPT_URL" | python3 - \
  --queue-url "https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA" \
  --region "us-east-1" \
  --outdir "$OUTDIR"
