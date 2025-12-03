#!/bin/bash
# post-run script - downloads and executes Python script from GitHub
# Python script fetches all metadata from Seqera Platform API using TOWER_* environment variables
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/data-yaml/seqera-smoke-test/parse-wrroc/scripts/post_run_sqs.py"

echo "Downloading and executing post-run script from GitHub..."
curl -sSfL "$SCRIPT_URL" | python3 -
