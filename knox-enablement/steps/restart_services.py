"""
Step: Restart all services that require restart after configuration changes.
This is the final step that applies all config changes by restarting affected services.
"""

import time
from modules import get_ambari_state
from modules.service_utils import ServiceUtils
from steps.base import get_ambari_configs


# Services to check for restart (in order of dependency)
SERVICES_TO_RESTART = [
    "HDFS",
    "YARN", 
    "MAPREDUCE2",
    "HIVE",
    "TEZ",
    "RANGER",
    "RANGER_KMS",
    "KNOX",
]


def run():
    """
    Restart all services that have stale configurations.
    
    This step:
    1. Waits briefly for Ambari to refresh service state
    2. Checks each service for stale configs
    3. Restarts services that need it (in dependency order)
    4. Always restarts Knox to apply topology/whitelist changes
    
    Idempotent: Safe to run multiple times.
    """
    print("\n[Step Final] Restarting Services with Stale Configs")
    
    # Re-initialize state to get fresh data from API
    print("  Refreshing Ambari state...")
    state = get_ambari_state(refresh=True)
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    
    # Give Ambari a moment to detect stale configs after any restart
    print("  Waiting for Ambari to refresh service state (10s)...")
    time.sleep(10)
    
    # Check which services need restart
    print(f"  Checking services: {', '.join(SERVICES_TO_RESTART)}")
    
    services_needing_restart = service_utils.get_services_requiring_restart(SERVICES_TO_RESTART)
    print(f"  Services with stale configs: {services_needing_restart if services_needing_restart else 'None'}")
    
    # Always include Knox (to apply topology/whitelist changes)
    if "KNOX" not in services_needing_restart:
        services_needing_restart.append("KNOX")
    
    if services_needing_restart:
        print(f"\n  Services to restart: {', '.join(services_needing_restart)}")
        
        # Restart in dependency order
        ordered_restarts = [s for s in SERVICES_TO_RESTART if s in services_needing_restart]
        
        for service_name in ordered_restarts:
            print(f"\n  --- {service_name} ---")
            success = service_utils.restart_service(service_name)
            if success:
                print(f"  ✓ {service_name} restarted successfully.")
            else:
                print(f"  ✗ Warning: {service_name} restart may have issues.")
    else:
        print("  No services require restart.")
    
    print("\n[Step Final] Complete - All services restarted")

