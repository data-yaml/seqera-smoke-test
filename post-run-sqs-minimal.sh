#!/bin/bash
# Minimal post-run script - downloads and executes Python script from GitHub
set -euo pipefail
SCRIPT_URL="https://raw.githubusercontent.com/data-yaml/seqera-smoke-test/parse-wrroc/scripts/post_run_sqs.py"
echo "Downloading post-run script from GitHub..."
curl -sSfL "$SCRIPT_URL" | python3 - \
  --queue-url "https://sqs.us-east-1.amazonaws.com/850787717197/sales-prod-PackagerQueue-2BfTcvCBFuJA" \
  --region "us-east-1" \
  --outdir "${NXF_PARAMS_outdir:-}"
