"""
Step: Create a Ranger policy to allow public group access to Ambari via Knox.
"""
import sys
import requests
from requests.auth import HTTPBasicAuth
from knox_setup.modules import get_ambari_state
from knox_setup.modules.service_utils import ServiceUtils
from knox_setup.steps.base import get_ambari_configs
from knox_setup.config.settings import RangerConfig


def run(timeout=60, protocol: str = "http"):
    print("\n[Step] Adding Ranger Policy for Public Group Access to Ambari")

    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)

    # Get Ranger Host
    ranger_host = service_utils.get_component_host("RANGER", "RANGER_ADMIN")
    if not ranger_host:
        print("  ✗ ERROR: Could not determine Ranger Admin host", file=sys.stderr)
        return

    print(f"  Ranger Admin Host: {ranger_host}")

    base_url = f"{protocol}://{ranger_host}:{RangerConfig.PORT}/service/public/v2/api"
    auth = HTTPBasicAuth(RangerConfig.USERNAME, RangerConfig.PASSWORD)
    headers = {"Content-Type": "application/json"}

    # 1. Find Knox Service in Ranger
    print("  Finding Knox service in Ranger...")
    try:
        resp = requests.get(f"{base_url}/service", auth=auth, headers=headers, timeout=timeout)
        resp.raise_for_status()
        services = resp.json()

        knox_service_name = None
        for service in services:
            if service.get("type") == "knox":
                knox_service_name = service.get("name")
                break

        if not knox_service_name:
            print("  ✗ ERROR: Could not find a service of type 'knox' in Ranger", file=sys.stderr)
            return

        print(f"  ✓ Found Knox Service: {knox_service_name}")

    except Exception as e:
        print(f"  ✗ ERROR: Failed to fetch services from Ranger: {e}", file=sys.stderr)
        return

    # 2. Check if policy already exists
    policy_name = "[knox-enablement-automation] ambari_public_access"
    print(f"  Checking for existing policy '{policy_name}'...")

    try:
        resp = requests.get(
            f"{base_url}/service/{knox_service_name}/policy",
            auth=auth,
            headers=headers,
            params={"policyName": policy_name},
            timeout=timeout,
        )
        resp.raise_for_status()
        existing_policies = resp.json()

        if existing_policies and len(existing_policies) > 0:
             print(f"  ✓ Policy '{policy_name}' already exists. Skipping creation.")
             return

    except Exception as e:
        print(f"  ✗ Warning: Failed to check existing policies: {e}", file=sys.stderr)

    # 3. Create Policy
    print(f"  Creating policy '{policy_name}'...")

    policy_data = {
        "isEnabled": True,
        "service": knox_service_name,
        "name": policy_name,
        "description": "Allow public group access to Ambari via Knox",
        "resources": {
            "topology": {
                "values": ["default"],
                "isExcludes": False,
                "isRecursive": False
            },
            "service": {
                "values": ["AMBARI", "AMBARIUI"],
                "isExcludes": False,
                "isRecursive": False
            }
        },
        "policyItems": [
            {
                "accesses": [
                    {"type": "allow", "isAllowed": True}
                ],
                "users": [],
                "groups": ["public"],
                "conditions": [],
                "delegateAdmin": False
            }
        ]
    }

    try:
        resp = requests.post(
            f"{base_url}/policy",
            auth=auth,
            headers=headers,
            json=policy_data,
            timeout=timeout,
        )
        resp.raise_for_status()
        print(f"  ✓ Policy '{policy_name}' created successfully (ID: {resp.json().get('id')})")

    except Exception as e:
        print(f"  ✗ ERROR: Failed to create policy: {e}", file=sys.stderr)
        if hasattr(e, 'response') and e.response is not None:
             print(f"  Response: {e.response.text}")

    print("\n[Step] Complete")

