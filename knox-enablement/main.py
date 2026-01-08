#!/usr/bin/env python3
"""
Knox Enablement for Ambari BigData Cluster
"""

import sys
from steps import (
    set_proxy_users, 
    start_knox, 
    update_topology, 
    update_whitelist, 
    restart_services, 
    export_knox_cert, 
    ambari_sso_setup,
    ambari_ldap_setup,
    import_knox_cert,
    restart_ambari,
    add_ranger_policy,
)


# ============================================================================
# STEP REGISTRY
# ============================================================================

STEPS = {
    "start_knox": start_knox.run,
    "set_proxy_users": set_proxy_users.run,
    "update_topology": update_topology.run,
    "update_whitelist": update_whitelist.run,
    "restart_services": restart_services.run,
    "export_knox_cert": export_knox_cert.run,
    "ambari_sso_setup": ambari_sso_setup.run,
    "ambari_ldap_setup": ambari_ldap_setup.run,
    "import_knox_cert": import_knox_cert.run,
    "restart_ambari": restart_ambari.run,
    "add_ranger_policy": add_ranger_policy.run,
}

# ============================================================================
# FLOWS - Named sequences of steps
# ============================================================================

FLOWS = {
    "knox_proxy_setup": [
        "start_knox",
        "set_proxy_users",
        "update_topology",
        "update_whitelist",
        "restart_services",
    ],
    "knox_sso_setup": [
        "start_knox",
        "set_proxy_users",
        "update_topology",
        "update_whitelist",
        "restart_services",
        "export_knox_cert",
        "ambari_sso_setup",
        "ambari_ldap_setup",
        "import_knox_cert",
        "restart_ambari",
        "add_ranger_policy",
        "restart_services",  # Final restart after Ambari comes back up
    ],
}


def run_flow(flow_name: str):
    """Execute a named flow (sequence of steps)."""
    steps = FLOWS[flow_name]
    
    print("=" * 60)
    print(f"KNOX ENABLEMENT - {flow_name.upper()}")
    print(f"Steps: {' → '.join(steps)}")
    print("=" * 60)

    for step_name in steps:
        print(f"\n{'=' * 60}")
        print(f"Executing: {step_name}")
        print("=" * 60)
        STEPS[step_name]()

    print("\n" + "=" * 60)
    print(f"FLOW '{flow_name}' COMPLETED SUCCESSFULLY")
    print("=" * 60)


def print_usage():
    """Print usage information."""
    print("Usage: python main.py <step_or_flow>")
    print("\nAvailable steps:")
    for step_name in STEPS:
        print(f"  - {step_name}")
    print("\nAvailable flows:")
    for flow_name, steps in FLOWS.items():
        print(f"  - {flow_name} ({' → '.join(steps)})")


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(1)

    target = sys.argv[1]

    if target in FLOWS:
        run_flow(target)
    elif target in STEPS:
        print(f"Executing: {target}")
        STEPS[target]()
        print(f"\nCompleted: {target}")
    else:
        print(f"Unknown step or flow: {target}")
        print_usage()
        sys.exit(1)


if __name__ == "__main__":
    main()
