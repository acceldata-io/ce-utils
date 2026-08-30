#!/usr/bin/env python3
"""
Knox Enablement for Ambari BigData Cluster
"""
import argparse
import sys
from knox_setup.steps import (
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


def main():
    """Main entry point."""

    all_arg_names = list(STEPS.keys() | FLOWS.keys())

    epilogue_text = "\n\t- ".join(["Valid targets are: "]+sorted(all_arg_names))
    epilogue_text += "\nSee README.md for more details on valid steps and flows."

    parser = argparse.ArgumentParser(description="Knox Enablement for Ambari", epilog=epilogue_text, formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument("--with-https", "-s", action="store_true", help="Use SSL for Ambari URLs (default: http)")
    parser.add_argument("--with-knox-http", "-k", action="store_false", help="Disable using https for Ambari SSO. (default: https)")
    parser.add_argument("target", metavar="TARGET", choices=all_arg_names, help="Step or flow to execute")

    args = parser.parse_args()

    protocol = "https" if args.with_https else "http"
    knox_protocol = "http" if args.with_knox_http else "https"

    target = args.target

    if target in FLOWS:
        run_flow(target)
    elif target in STEPS:
        print(f"Executing: {target}")
        if target == "ambari_sso_setup":
            STEPS[target](protocol=knox_protocol)
        else:
            STEPS[target](protocol)
        print(f"\nCompleted: {target}")
    else:
        print(f"Unknown step or flow: {target}")
        return 1


if __name__ == "__main__":
    main()
