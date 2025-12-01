#!/usr/bin/env python3
"""
Setup SQS Integration for Seqera Platform Workflows

Automatically discovers Quilt catalog configuration and updates TowerForge IAM roles
with SQS SendMessage permissions for the Packager Queue.

Usage:
    ./setup-sqs.py [--profile PROFILE] [--region REGION] [--yes]

Steps:
    0. Prompts for AWS Profile to use (default: none)
    1. Check quilt3 CLI for catalog URL (or prompt user)
    2. Query catalog/config.json to find region
    3. Search that region for CloudFormation stack with matching QuiltWebHost
    4. Retrieve ARN and URL for PackagerQueue
    5. Find TowerForge roles in that region
    6. Display all info and prompt to update role with SQS permissions
"""

import argparse
import json
import subprocess
import sys
from typing import Optional, Dict, Any, List
from urllib.request import urlopen
from urllib.error import URLError


class Color:
    """ANSI color codes for terminal output"""
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BOLD = '\033[1m'
    END = '\033[0m'


def print_header(text: str) -> None:
    """Print a formatted header"""
    print(f"\n{Color.BOLD}{'=' * 60}{Color.END}")
    print(f"{Color.BOLD}{text}{Color.END}")
    print(f"{Color.BOLD}{'=' * 60}{Color.END}\n")


def print_success(text: str) -> None:
    """Print success message"""
    print(f"{Color.GREEN}✓ {text}{Color.END}")


def print_warning(text: str) -> None:
    """Print warning message"""
    print(f"{Color.YELLOW}⚠ {text}{Color.END}")


def print_error(text: str) -> None:
    """Print error message"""
    print(f"{Color.RED}✗ {text}{Color.END}")


def get_quilt3_catalog() -> Optional[str]:
    """
    Get catalog URL from quilt3 CLI

    Returns:
        Catalog URL or None if quilt3 not available
    """
    try:
        result = subprocess.run(
            ['quilt3', 'config'],
            capture_output=True,
            text=True,
            check=True
        )
        catalog_url = result.stdout.strip()
        if catalog_url and catalog_url.startswith('http'):
            return catalog_url
        return None
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def fetch_json(url: str) -> Dict[str, Any]:
    """
    Fetch JSON from URL

    Args:
        url: URL to fetch

    Returns:
        Parsed JSON data

    Raises:
        URLError: If fetch fails
    """
    with urlopen(url, timeout=10) as response:
        return json.loads(response.read().decode('utf-8'))


def get_catalog_region(catalog_url: str) -> Optional[str]:
    """
    Get region from catalog's config.json

    Args:
        catalog_url: Catalog URL

    Returns:
        Region or None if not found
    """
    try:
        config_url = catalog_url.rstrip('/') + '/config.json'
        config = fetch_json(config_url)
        return config.get('region')
    except (URLError, json.JSONDecodeError, KeyError) as e:
        print_warning(f"Could not fetch catalog config.json: {e}")
        return None


def run_aws_command(args: List[str], profile: Optional[str] = None) -> Dict[str, Any]:
    """
    Run AWS CLI command and return JSON output

    Args:
        args: AWS CLI arguments
        profile: AWS profile to use

    Returns:
        Parsed JSON output

    Raises:
        subprocess.CalledProcessError: If command fails
    """
    cmd = ['aws'] + args + ['--output', 'json']
    if profile:
        cmd.extend(['--profile', profile])

    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return json.loads(result.stdout) if result.stdout else {}


def find_quilt_stack(region: str, catalog_url: str, profile: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Find CloudFormation stack matching catalog URL

    Args:
        region: AWS region to search
        catalog_url: Catalog URL to match
        profile: AWS profile to use

    Returns:
        Stack info or None if not found
    """
    print(f"Searching for Quilt CloudFormation stack in {region}...")

    try:
        # List all stacks
        stacks = run_aws_command(
            ['cloudformation', 'list-stacks', '--region', region],
            profile
        )

        # Normalize catalog URL for comparison
        def normalize_url(url: str) -> str:
            return url.replace('https://', '').replace('http://', '').rstrip('/')

        target_url = normalize_url(catalog_url)

        # Check each stack for QuiltWebHost output
        for stack_summary in stacks.get('StackSummaries', []):
            stack_name = stack_summary.get('StackName')
            if not stack_name:
                continue

            try:
                # Get stack details
                stack_details = run_aws_command(
                    ['cloudformation', 'describe-stacks', '--stack-name', stack_name, '--region', region],
                    profile
                )

                stack = stack_details.get('Stacks', [{}])[0]
                outputs = stack.get('Outputs', [])

                # Look for QuiltWebHost output
                quilt_web_host = None
                packager_queue = None

                for output in outputs:
                    if output.get('OutputKey') == 'QuiltWebHost':
                        quilt_web_host = output.get('OutputValue')
                    elif output.get('OutputKey') in ['PackagerQueue', 'PackagerQueueArn']:
                        value = output.get('OutputValue', '')
                        # If it's an ARN, extract the URL
                        if value.startswith('arn:aws:sqs:'):
                            # ARN format: arn:aws:sqs:region:account:queue-name
                            parts = value.split(':')
                            if len(parts) >= 6:
                                queue_region = parts[3]
                                account_id = parts[4]
                                queue_name = parts[5]
                                packager_queue = f"https://sqs.{queue_region}.amazonaws.com/{account_id}/{queue_name}"
                        else:
                            packager_queue = value

                # Check if this matches our catalog
                if quilt_web_host and normalize_url(quilt_web_host) == target_url:
                    print_success(f"Found stack: {stack_name}")

                    # Extract stack ARN to get account ID
                    stack_arn = stack.get('StackId', '')
                    account_id = None
                    if stack_arn:
                        parts = stack_arn.split(':')
                        if len(parts) >= 5:
                            account_id = parts[4]

                    return {
                        'stack_name': stack_name,
                        'stack_arn': stack_arn,
                        'region': region,
                        'account_id': account_id,
                        'catalog_url': quilt_web_host,
                        'packager_queue_url': packager_queue,
                    }

            except subprocess.CalledProcessError:
                # Skip stacks we can't access
                continue

        return None

    except subprocess.CalledProcessError as e:
        print_error(f"Failed to list CloudFormation stacks: {e}")
        return None


def get_queue_arn(queue_url: str, region: str, profile: Optional[str] = None) -> Optional[str]:
    """
    Get queue ARN from queue URL

    Args:
        queue_url: SQS queue URL
        region: AWS region
        profile: AWS profile to use

    Returns:
        Queue ARN or None if not found
    """
    try:
        attrs = run_aws_command(
            ['sqs', 'get-queue-attributes', '--queue-url', queue_url, '--attribute-names', 'QueueArn', '--region', region],
            profile
        )
        return attrs.get('Attributes', {}).get('QueueArn')
    except subprocess.CalledProcessError as e:
        print_error(f"Failed to get queue ARN: {e}")
        return None


def find_tower_forge_roles(region: str, profile: Optional[str] = None) -> List[Dict[str, str]]:
    """
    Find TowerForge IAM roles in the region

    Args:
        region: AWS region
        profile: AWS profile to use

    Returns:
        List of role info dicts
    """
    print(f"\nSearching for TowerForge roles in {region}...")

    try:
        roles = run_aws_command(['iam', 'list-roles'], profile)

        tower_roles = []
        for role in roles.get('Roles', []):
            role_name = role.get('RoleName', '')
            if 'TowerForge' in role_name and 'FargateRole' in role_name:
                tower_roles.append({
                    'role_name': role_name,
                    'role_arn': role.get('Arn', ''),
                })

        if tower_roles:
            print_success(f"Found {len(tower_roles)} TowerForge role(s)")
            for role in tower_roles:
                print(f"  - {role['role_name']}")
        else:
            print_warning("No TowerForge roles found")

        return tower_roles

    except subprocess.CalledProcessError as e:
        print_error(f"Failed to list IAM roles: {e}")
        return []


def get_role_policy(role_name: str, policy_name: str, profile: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Get inline role policy document

    Args:
        role_name: IAM role name
        policy_name: Policy name
        profile: AWS profile to use

    Returns:
        Policy document or None if not found
    """
    try:
        result = run_aws_command(
            ['iam', 'get-role-policy', '--role-name', role_name, '--policy-name', policy_name],
            profile
        )
        policy_doc = result.get('PolicyDocument')

        # Policy document might be URL-encoded string, decode if needed
        if isinstance(policy_doc, str):
            from urllib.parse import unquote
            policy_doc = json.loads(unquote(policy_doc))

        return policy_doc
    except subprocess.CalledProcessError:
        return None


def check_sqs_permission(role_name: str, queue_arn: str, profile: Optional[str] = None) -> bool:
    """
    Check if role already has SQS SendMessage permission for the queue

    Args:
        role_name: IAM role name
        queue_arn: SQS queue ARN
        profile: AWS profile to use

    Returns:
        True if permission exists
    """
    try:
        # List inline policies
        policies = run_aws_command(
            ['iam', 'list-role-policies', '--role-name', role_name],
            profile
        )

        for policy_name in policies.get('PolicyNames', []):
            policy_doc = get_role_policy(role_name, policy_name, profile)
            if not policy_doc or not isinstance(policy_doc, dict):
                continue

            # Check each statement for SQS permission
            statements = policy_doc.get('Statement', [])
            if not isinstance(statements, list):
                continue

            for statement in statements:
                if not isinstance(statement, dict):
                    continue

                actions = statement.get('Action', [])
                if isinstance(actions, str):
                    actions = [actions]
                elif not isinstance(actions, list):
                    continue

                resources = statement.get('Resource', [])
                if isinstance(resources, str):
                    resources = [resources]
                elif not isinstance(resources, list):
                    continue

                # Check if this statement grants sqs:SendMessage for our queue
                has_send_message = 'sqs:SendMessage' in actions or 'sqs:*' in actions
                has_queue = queue_arn in resources or '*' in resources

                if has_send_message and has_queue:
                    return True

        return False

    except (subprocess.CalledProcessError, AttributeError, TypeError) as e:
        print_warning(f"Error checking policy for {role_name}: {e}")
        return False


def add_sqs_permission(role_name: str, queue_arn: str, profile: Optional[str] = None) -> bool:
    """
    Add SQS SendMessage permission to role's nextflow-policy

    Args:
        role_name: IAM role name
        queue_arn: SQS queue ARN
        profile: AWS profile to use

    Returns:
        True if successful
    """
    try:
        # Get existing nextflow-policy
        policy_doc = get_role_policy(role_name, 'nextflow-policy', profile)

        if not policy_doc:
            print_error("Role does not have 'nextflow-policy' inline policy")
            return False

        # Add SQS statement
        sqs_statement = {
            "Sid": "SQSSendMessage",
            "Effect": "Allow",
            "Action": "sqs:SendMessage",
            "Resource": queue_arn
        }

        policy_doc['Statement'].append(sqs_statement)

        # Write updated policy
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(policy_doc, f, indent=2)
            policy_file = f.name

        try:
            run_aws_command(
                ['iam', 'put-role-policy', '--role-name', role_name, '--policy-name', 'nextflow-policy', '--policy-document', f'file://{policy_file}'],
                profile
            )
            print_success(f"Updated {role_name} with SQS permission")
            return True
        finally:
            import os
            os.unlink(policy_file)

    except subprocess.CalledProcessError as e:
        print_error(f"Failed to update policy: {e}")
        return False


def prompt_yes_no(question: str, default: bool = False) -> bool:
    """
    Prompt user for yes/no answer

    Args:
        question: Question to ask
        default: Default answer

    Returns:
        User's choice
    """
    default_str = 'Y/n' if default else 'y/N'
    answer = input(f"{question} ({default_str}): ").strip().lower()

    if not answer:
        return default

    return answer in ['y', 'yes']


def main():
    """Main execution"""
    parser = argparse.ArgumentParser(
        description='Setup SQS Integration for Seqera Platform Workflows',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('--profile', help='AWS profile to use')
    parser.add_argument('--region', help='AWS region (will auto-detect from catalog if not specified)')
    parser.add_argument('--catalog', help='Catalog URL (will use quilt3 CLI if not specified)')
    parser.add_argument('--yes', '-y', action='store_true', help='Auto-approve all prompts')

    args = parser.parse_args()

    print_header("Seqera Platform SQS Integration Setup")

    # Step 0: Prompt for AWS profile if not provided
    aws_profile = args.profile
    if not aws_profile and not args.yes:
        profile_input = input("AWS Profile to use (press Enter for default/none): ").strip()
        if profile_input:
            aws_profile = profile_input

    if aws_profile:
        print(f"Using AWS profile: {Color.BOLD}{aws_profile}{Color.END}\n")
    else:
        print("Using default AWS credentials\n")

    # Step 1: Get catalog URL
    catalog_url = args.catalog

    if not catalog_url:
        print("Checking quilt3 CLI configuration...")
        catalog_url = get_quilt3_catalog()

        if catalog_url:
            print_success(f"Found quilt3 catalog: {catalog_url}")
        else:
            print_warning("quilt3 CLI not configured")
            if args.yes:
                print_error("--yes mode requires --catalog or quilt3 CLI configuration")
                sys.exit(1)
            catalog_url = input("\nEnter catalog URL: ").strip()
            if not catalog_url:
                print_error("Catalog URL required")
                sys.exit(1)

    # Step 2: Get region from catalog config
    region = args.region
    if not region:
        print("\nFetching catalog configuration...")
        region = get_catalog_region(catalog_url)
        if region:
            print_success(f"Found catalog region: {region}")
        else:
            if args.yes:
                print_error("--yes mode requires --region or catalog config.json with region")
                sys.exit(1)
            region = input("\nEnter AWS region: ").strip() or 'us-east-1'

    print(f"\nUsing region: {Color.BOLD}{region}{Color.END}")

    # Step 3: Find CloudFormation stack
    stack_info = find_quilt_stack(region, catalog_url, aws_profile)

    if not stack_info:
        print_error(f"No Quilt CloudFormation stack found matching catalog: {catalog_url}")
        sys.exit(1)

    # Step 4: Get queue information
    queue_url = stack_info.get('packager_queue_url')
    if not queue_url:
        print_error("Stack does not have PackagerQueue output")
        sys.exit(1)

    print_success(f"Found PackagerQueue: {queue_url}")

    queue_arn = get_queue_arn(queue_url, region, aws_profile)
    if not queue_arn:
        print_error("Could not retrieve queue ARN")
        sys.exit(1)

    print_success(f"Queue ARN: {queue_arn}")

    # Step 5: Find TowerForge roles
    tower_roles = find_tower_forge_roles(region, aws_profile)

    if not tower_roles:
        print_warning("No TowerForge roles found - you may need to create a compute environment first")
        sys.exit(0)

    # Step 6: Display information and prompt to update
    print_header("Configuration Summary")
    print(f"Catalog:        {catalog_url}")
    print(f"Stack:          {stack_info['stack_name']}")
    print(f"Region:         {region}")
    print(f"Account:        {stack_info.get('account_id', 'unknown')}")
    print(f"Queue URL:      {queue_url}")
    print(f"Queue ARN:      {queue_arn}")
    print(f"\nTowerForge Roles Found: {len(tower_roles)}")

    # Check and update each role
    for role in tower_roles:
        role_name = role['role_name']
        print(f"\n{Color.BOLD}Role: {role_name}{Color.END}")

        # Check if permission already exists
        if check_sqs_permission(role_name, queue_arn, aws_profile):
            print_success("Already has SQS SendMessage permission")
            continue

        print_warning("Missing SQS SendMessage permission")

        # Prompt to update
        if args.yes or prompt_yes_no(f"Add SQS permission to {role_name}?", default=True):
            if add_sqs_permission(role_name, queue_arn, aws_profile):
                print_success("Permission added successfully")
            else:
                print_error("Failed to add permission")
        else:
            print("Skipped")

    print_header("Setup Complete")
    print("\nNext steps:")
    print("1. Update your Nextflow workflow to send SQS messages in workflow.onComplete")
    print(f"2. Use queue URL: {queue_url}")
    print("3. Launch workflow via Seqera Platform")
    print()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nCancelled by user")
        sys.exit(1)
    except Exception as e:
        print_error(f"Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
