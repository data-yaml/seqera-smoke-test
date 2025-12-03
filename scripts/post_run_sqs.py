#!/usr/bin/env python3
"""
Post-run script for Seqera Platform - sends SQS message with workflow metadata
Downloads and executes from GitHub to bypass Seqera Platform's 1024-byte post-run script limit

This version fetches comprehensive workflow details from Seqera Platform API including
resolved parameters and configuration.
"""

import argparse
import json
import os
import sys
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


def print_header(msg: str):
    """Print a formatted header"""
    sep = "=" * 60
    print(f"\n{sep}\n{msg}\n{sep}\n")


def fetch_workflow_details() -> Optional[Dict[str, Any]]:
    """
    Fetch workflow details from Seqera Platform API using TOWER_* environment variables

    Returns comprehensive workflow information including:
    - Resolved parameters
    - Configuration
    - Launch details
    - Status and metadata
    """
    print_header("Fetching Workflow Details from Seqera Platform API")

    # Get required environment variables
    access_token = os.getenv("TOWER_ACCESS_TOKEN")
    workflow_id = os.getenv("TOWER_WORKFLOW_ID")
    workspace_id = os.getenv("TOWER_WORKSPACE_ID")

    # Check for required variables
    if not access_token:
        print("⚠ Warning: TOWER_ACCESS_TOKEN not set, skipping API fetch")
        return None
    if not workflow_id:
        print("⚠ Warning: TOWER_WORKFLOW_ID not set, skipping API fetch")
        return None

    # Determine API endpoint (default to cloud.seqera.io)
    api_base = os.getenv("TOWER_API_ENDPOINT", "https://api.cloud.seqera.io")

    # Build API URL
    if workspace_id:
        url = f"{api_base}/workflow/{workflow_id}?workspaceId={workspace_id}"
    else:
        url = f"{api_base}/workflow/{workflow_id}"

    print(f"API URL: {url}")
    print(f"Workflow ID: {workflow_id}")
    if workspace_id:
        print(f"Workspace ID: {workspace_id}")

    try:
        # Make API request
        request = Request(url)
        request.add_header("Authorization", f"Bearer {access_token}")
        request.add_header("Accept", "application/json")

        with urlopen(request, timeout=30) as response:
            if response.status == 200:
                data = json.loads(response.read().decode('utf-8'))
                workflow = data.get("workflow", {})

                print(f"✓ Successfully fetched workflow details")
                print(f"  Workflow: {workflow.get('runName', 'N/A')}")
                print(f"  Status: {workflow.get('status', 'N/A')}")
                print(f"  Project: {workflow.get('projectName', 'N/A')}")

                return workflow
            else:
                print(f"⚠ Warning: API returned status {response.status}")
                return None

    except HTTPError as e:
        print(f"⚠ Warning: HTTP error fetching workflow: {e.code} - {e.reason}")
        if e.code == 401:
            print("  Token may be expired or invalid")
        return None
    except URLError as e:
        print(f"⚠ Warning: Network error fetching workflow: {e.reason}")
        return None
    except Exception as e:
        print(f"⚠ Warning: Unexpected error fetching workflow: {e}")
        return None


def extract_api_metadata(workflow_data: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Extract relevant metadata from Seqera Platform API workflow response

    Extracts:
    - Resolved parameters (params)
    - Configuration values
    - Launch details
    - Compute environment info
    """
    if not workflow_data:
        return {}

    print("\nExtracting metadata from API response...")

    metadata = {}

    # Basic workflow info
    metadata["api_run_name"] = workflow_data.get("runName")
    metadata["api_project_name"] = workflow_data.get("projectName")
    metadata["api_status"] = workflow_data.get("status")
    metadata["api_session_id"] = workflow_data.get("sessionId")

    # Resolved parameters (this is what you're looking for!)
    params = workflow_data.get("params")
    if params:
        metadata["api_params"] = params
        print(f"✓ Found resolved parameters:")
        print(f"  {json.dumps(params, indent=2)}")

    # Configuration
    config = workflow_data.get("configText")
    if config:
        metadata["api_config_text"] = config
        print(f"✓ Found configuration text ({len(config)} chars)")

    # Launch details
    launch = workflow_data.get("launch")
    if launch:
        metadata["api_launch_id"] = launch.get("id")
        metadata["api_launch_pipeline"] = launch.get("pipeline")
        metadata["api_launch_revision"] = launch.get("revision")
        metadata["api_launch_config_profiles"] = launch.get("configProfiles")

    # Compute environment
    metadata["api_compute_env_id"] = workflow_data.get("computeEnvId")
    metadata["api_compute_env_name"] = workflow_data.get("computeEnv", {}).get("name")

    # Work directory
    metadata["api_workdir"] = workflow_data.get("workDir")

    # Execution details
    metadata["api_start"] = workflow_data.get("start")
    metadata["api_complete"] = workflow_data.get("complete")
    metadata["api_duration"] = workflow_data.get("duration")

    # Container
    metadata["api_container"] = workflow_data.get("container")

    # Remove None values
    metadata = {k: v for k, v in metadata.items() if v is not None}

    print(f"\n✓ Extracted {len(metadata)} fields from API response")

    return metadata


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


def build_sqs_message(outdir: str, wrroc_metadata: Dict[str, Any], api_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """Build SQS message body with workflow, WRROC, and API metadata"""

    # Extract Seqera Platform environment variables (TOWER_*)
    metadata = {
        # Run identification
        "tower_workflow_id": os.getenv("TOWER_WORKFLOW_ID", "unknown"),
        "tower_run_name": os.getenv("TOWER_RUN_NAME", "unknown"),
        "tower_project_id": os.getenv("TOWER_PROJECT_ID"),
        "tower_workspace_id": os.getenv("TOWER_WORKSPACE_ID"),
        "tower_user_id": os.getenv("TOWER_USER_ID"),
        # Status and outcome
        "tower_workflow_status": os.getenv("TOWER_WORKFLOW_STATUS", "SUCCEEDED"),
        "tower_workflow_start": os.getenv("TOWER_WORKFLOW_START"),
        "tower_workflow_complete": os.getenv("TOWER_WORKFLOW_COMPLETE"),
        # Storage
        "tower_workdir": os.getenv("TOWER_WORKDIR"),
        "tower_outdir": os.getenv("TOWER_OUTDIR"),
        # Pipeline metadata
        "tower_pipeline": os.getenv("TOWER_PIPELINE"),
        "tower_pipeline_revision": os.getenv("TOWER_PIPELINE_REVISION"),
        "tower_nextflow_version": os.getenv("TOWER_NEXTFLOW_VERSION"),
        "tower_executor": os.getenv("TOWER_EXECUTOR"),
        # Legacy Nextflow variables (if available)
        "nextflow_version": os.getenv("NXF_VER"),
        "workflow_name": os.getenv("NXF_WORKFLOW_NAME"),
        "session_id": os.getenv("NXF_SESSION_ID"),
        "timestamp": datetime.utcnow().isoformat() + "Z"
    }

    # Remove None values
    metadata = {k: v for k, v in metadata.items() if v is not None}

    # Merge WRROC metadata
    metadata.update(wrroc_metadata)

    # Merge API metadata (including resolved params!)
    metadata.update(api_metadata)

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
    print_header("SQS Integration - Post-Run Script")

    # Step 1: Fetch workflow details from Seqera Platform API
    # This gets us ALL the params including sqs_queue_url, sqs_region, outdir
    workflow_data = fetch_workflow_details()
    if not workflow_data:
        print("ERROR: Failed to fetch workflow data from Seqera Platform API")
        sys.exit(1)

    # Extract params from API response
    params = workflow_data.get("params", {})
    queue_url = params.get("sqs_queue_url")
    region = params.get("sqs_region", "us-east-1")
    outdir = params.get("outdir")

    # Validate required parameters
    if not outdir:
        print("ERROR: params.outdir not set in workflow")
        sys.exit(1)

    if not queue_url:
        print("ERROR: params.sqs_queue_url not set in workflow")
        print("Please set --params.sqs_queue_url when launching")
        sys.exit(1)

    print(f"Queue URL: {queue_url}")
    print(f"Region: {region}")
    print(f"Output folder: {outdir}")

    # Step 2: Check AWS CLI and credentials
    if not check_aws_cli():
        print_header("ERROR: AWS CLI Not Available")
        print("The AWS CLI is not installed or not in PATH in this compute environment.")
        sys.exit(1)

    if not check_aws_credentials():
        print_header("ERROR: AWS Credentials Not Configured")
        print("AWS credentials are not available in this compute environment.")
        sys.exit(1)

    # Step 3: Extract API metadata
    api_metadata = extract_api_metadata(workflow_data)

    if api_metadata:
        print("\nExtracted API metadata:")
        print(json.dumps(api_metadata, indent=2))

    # Step 4: Wait for WRROC file
    wrroc_path = f"{outdir}/ro-crate-metadata.json"
    wrroc_found = wait_for_wrroc_file(wrroc_path)

    # Step 5: Extract WRROC metadata if file exists
    wrroc_metadata = {}
    if wrroc_found:
        wrroc_metadata = extract_wrroc_metadata(wrroc_path)
        if wrroc_metadata:
            print("\nExtracted WRROC metadata:")
            print(json.dumps(wrroc_metadata, indent=2))

    # Step 6: Build and send SQS message
    message = build_sqs_message(outdir, wrroc_metadata, api_metadata)
    success = send_sqs_message(queue_url, region, message)

    if success:
        print("\n✓ Post-run script completed successfully")
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
