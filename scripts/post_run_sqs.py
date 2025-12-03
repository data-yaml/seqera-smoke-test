#!/usr/bin/env python3
"""
Post-run script for Seqera Platform - sends SQS message with workflow metadata
Downloads and executes from GitHub to bypass Seqera Platform's 1024-byte post-run script limit
"""

import argparse
import json
import os
import sys
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional


def print_header(msg: str):
    """Print a formatted header"""
    sep = "=" * 60
    print(f"\n{sep}\n{msg}\n{sep}\n")


def check_aws_cli() -> bool:
    """Check if AWS CLI is available"""
    print("Checking AWS CLI availability...")
    try:
        result = subprocess.run(
            ["aws", "--version"],
            capture_output=True,
            text=True,
            check=False
        )
        if result.returncode == 0:
            print(f"✓ AWS CLI found: {result.stdout.strip()}")
            return True
        else:
            print(f"✗ AWS CLI check failed: {result.stderr}")
            return False
    except FileNotFoundError:
        print("✗ AWS CLI not found in PATH")
        return False


def check_aws_credentials() -> bool:
    """Check if AWS credentials are configured"""
    print("\nChecking AWS credentials...")
    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity"],
            capture_output=True,
            text=True,
            check=False
        )
        if result.returncode == 0:
            identity = json.loads(result.stdout)
            print(f"✓ AWS credentials found")
            print(f"  Account: {identity.get('Account')}")
            print(f"  User/Role: {identity.get('Arn')}")
            return True
        else:
            print(f"✗ AWS credentials check failed: {result.stderr}")
            return False
    except Exception as e:
        print(f"✗ Error checking credentials: {e}")
        return False


def file_exists(path: str) -> bool:
    """Check if file exists (supports both local and S3 paths)"""
    if path.startswith("s3://"):
        result = subprocess.run(
            ["aws", "s3", "ls", path],
            capture_output=True,
            check=False
        )
        return result.returncode == 0
    else:
        return Path(path).exists() and Path(path).stat().st_size > 0


def wait_for_wrroc_file(wrroc_path: str, max_wait_seconds: int = 60) -> bool:
    """Wait for WRROC file to be written by nf-prov plugin"""
    import time

    path_type = "S3" if wrroc_path.startswith("s3://") else "Local"
    print(f"\nWaiting for WRROC file to be written by nf-prov plugin...")
    print(f"Target path: {wrroc_path}")
    print(f"Path type: {path_type}")

    check_interval = 0.5  # 500ms
    attempts = int(max_wait_seconds / check_interval)

    for i in range(attempts):
        if file_exists(wrroc_path):
            print(f"✓ WRROC file found: {wrroc_path}")
            return True
        time.sleep(check_interval)

    print(f"⚠ Warning: WRROC file not found after {max_wait_seconds}s")
    print(f"Expected path: {wrroc_path}")
    print("Proceeding with SQS notification, but WRROC file may be missing.")
    return False


def extract_wrroc_metadata(wrroc_path: str) -> Dict[str, Any]:
    """Extract metadata from WRROC file"""
    print("\nExtracting WRROC metadata...")

    temp_file = None
    try:
        # Download S3 file if needed
        if wrroc_path.startswith("s3://"):
            temp_file = "/tmp/wrroc-metadata.json"
            result = subprocess.run(
                ["aws", "s3", "cp", wrroc_path, temp_file],
                capture_output=True,
                check=False
            )
            if result.returncode != 0:
                print("⚠ Warning: Failed to download WRROC file from S3")
                return {}
            wrroc_path = temp_file

        # Parse WRROC JSON
        with open(wrroc_path) as f:
            wrroc = json.load(f)

        metadata = {}
        graph = wrroc.get("@graph", [])

        # Find root dataset
        root = next((e for e in graph if e.get("@id") == "./"), None)
        if root:
            metadata["wrroc_name"] = root.get("name")
            metadata["wrroc_date_published"] = root.get("datePublished")
            metadata["wrroc_license"] = root.get("license")

            author_id = root.get("author", {}).get("@id")
            if author_id:
                author = next((e for e in graph if e.get("@id") == author_id), None)
                if author:
                    metadata["wrroc_author_name"] = author.get("name")
                    metadata["wrroc_author_orcid"] = author_id

        # Find workflow run
        workflow_run = next(
            (e for e in graph
             if e.get("@type") == "CreateAction"
             and e.get("name", "").startswith("Nextflow workflow run")),
            None
        )
        if workflow_run:
            metadata["wrroc_run_id"] = workflow_run.get("@id", "").lstrip("#")
            metadata["wrroc_start_time"] = workflow_run.get("startTime")
            metadata["wrroc_end_time"] = workflow_run.get("endTime")

        # Find main workflow
        main_workflow = next((e for e in graph if e.get("@id") == "main-sqs.nf"), None)
        if main_workflow:
            metadata["wrroc_runtime_platform"] = main_workflow.get("runtimePlatform")
            prog_lang = main_workflow.get("programmingLanguage", {})
            if isinstance(prog_lang, dict):
                metadata["wrroc_programming_language"] = prog_lang.get("@id")

        # Remove None values
        metadata = {k: v for k, v in metadata.items() if v is not None}

        print(f"Extracted {len(metadata)} metadata fields from WRROC file")
        return metadata

    except Exception as e:
        print(f"⚠ Warning: Failed to extract WRROC metadata: {e}")
        return {}
    finally:
        # Clean up temp file
        if temp_file and Path(temp_file).exists():
            Path(temp_file).unlink()


def build_sqs_message(outdir: str, wrroc_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """Build SQS message body with workflow and WRROC metadata"""

    # Extract Nextflow environment variables provided by Seqera Platform
    metadata = {
        "nextflow_version": os.getenv("NXF_VER", "unknown"),
        "workflow_name": os.getenv("NXF_WORKFLOW_NAME", "unknown"),
        "workflow_id": os.getenv("NXF_WORKFLOW_ID", "unknown"),
        "session_id": os.getenv("NXF_SESSION_ID", "unknown"),
        "container": os.getenv("NXF_CONTAINER", "none"),
        "success": True,  # Post-run script only runs on success
        "timestamp": datetime.utcnow().isoformat() + "Z"
    }

    # Merge WRROC metadata
    metadata.update(wrroc_metadata)

    message = {
        "source_prefix": f"{outdir}/",
        "metadata": metadata,
        "commit_message": f"Seqera Platform workflow completed at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    }

    return message


def send_sqs_message(queue_url: str, region: str, message: Dict[str, Any]) -> bool:
    """Send SQS message"""
    print_header("Sending SQS Message")

    message_json = json.dumps(message, indent=2)
    print("Message body:")
    print(message_json)
    print()

    try:
        result = subprocess.run(
            [
                "aws", "sqs", "send-message",
                "--queue-url", queue_url,
                "--region", region,
                "--message-body", message_json
            ],
            capture_output=True,
            text=True,
            check=True
        )

        print_header("✓✓✓ SQS Integration SUCCESS ✓✓✓")
        print("Message sent successfully to queue!")
        print(f"\nQueue URL: {queue_url}")
        print(f"Region: {region}")
        print(f"\nAWS SQS Response:")
        print(result.stdout)
        return True

    except subprocess.CalledProcessError as e:
        print_header("ERROR: SQS Message Send Failed")
        print(f"Exit Code: {e.returncode}")
        print(f"Queue URL: {queue_url}")
        print(f"Region: {region}")
        print(f"\nError details:")
        print(e.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(
        description="Post-run script for Seqera Platform - sends SQS message with workflow metadata"
    )
    parser.add_argument(
        "--queue-url",
        required=True,
        help="SQS queue URL"
    )
    parser.add_argument(
        "--region",
        required=True,
        help="AWS region"
    )
    parser.add_argument(
        "--outdir",
        required=True,
        help="Output directory (from NXF_PARAMS_outdir)"
    )

    args = parser.parse_args()

    # Validate outdir
    if not args.outdir:
        print("ERROR: Output directory not set (NXF_PARAMS_outdir)")
        print("This script must be run as a Seqera Platform post-run script")
        sys.exit(1)

    print_header("SQS Integration - Post-Run Script")
    print(f"Queue URL: {args.queue_url}")
    print(f"Region: {args.region}")
    print(f"Output folder: {args.outdir}")

    # Step 1: Check AWS CLI and credentials
    if not check_aws_cli():
        print_header("ERROR: AWS CLI Not Available")
        print("The AWS CLI is not installed or not in PATH in this compute environment.")
        sys.exit(1)

    if not check_aws_credentials():
        print_header("ERROR: AWS Credentials Not Configured")
        print("AWS credentials are not available in this compute environment.")
        sys.exit(1)

    # Step 2: Wait for WRROC file
    wrroc_path = f"{args.outdir}/ro-crate-metadata.json"
    wrroc_found = wait_for_wrroc_file(wrroc_path)

    # Step 3: Extract WRROC metadata if file exists
    wrroc_metadata = {}
    if wrroc_found:
        wrroc_metadata = extract_wrroc_metadata(wrroc_path)
        if wrroc_metadata:
            print("\nExtracted WRROC metadata:")
            print(json.dumps(wrroc_metadata, indent=2))

    # Step 4: Build and send SQS message
    message = build_sqs_message(args.outdir, wrroc_metadata)
    success = send_sqs_message(args.queue_url, args.region, message)

    if success:
        print("\n✓ Post-run script completed successfully")
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
