"""
Step: Verify Knox is installed and ready.
If Knox is not installed, raises an error asking user to install manually.
"""

from modules import get_ambari_state
from modules.service_utils import ServiceUtils
from steps.base import get_ambari_configs


class KnoxNotInstalledError(Exception):
    """Raised when Knox is not installed."""
    pass


def run():
    """
    Verify Knox is installed and start it.
    
    If Knox is not installed, raises KnoxNotInstalledError with instructions.
    If Knox is installed but stopped, starts it.
    After Knox is running, starts Demo LDAP.
    
    Note: Service restarts are handled by the final restart_services step.
    
    Idempotent: Safe to run multiple times.
    """
    print("\n[Step 0] Verifying Knox Installation")
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    
    # Check if Knox is installed
    if not state.is_service_installed("KNOX"):
        print("\n" + "=" * 60)
        print("ERROR: Knox is not installed!")
        print("=" * 60)
        print("\nPlease install Knox manually via Ambari UI:")
        print("  1. Go to Ambari UI -> Services -> Add Service")
        print("  2. Select 'Knox' and follow the wizard")
        print("  3. Re-run this pipeline after installation")
        print("=" * 60 + "\n")
        raise KnoxNotInstalledError(
            "Knox is not installed. Please install Knox manually via Ambari UI and re-run this pipeline."
        )
    
    # Knox is installed - check state
    knox_state = service_utils.get_service_state("KNOX")
    print(f"  KNOX service found. State: {knox_state}")
    
    # Start Knox if not started
    if knox_state == "INSTALLED":
        print("  Knox is installed but not started. Starting...")
        success = service_utils.start_service("KNOX")
        if not success:
            raise RuntimeError("Failed to start Knox service")
        knox_state = service_utils.get_service_state("KNOX")
        print(f"  Knox state after start: {knox_state}")
    elif knox_state == "STARTED":
        print("  Knox is already running.")
    else:
        print(f"  Knox is in state: {knox_state}")
    
    # Start Demo LDAP
    knox_host = service_utils.get_component_host("KNOX", "KNOX_GATEWAY")
    if knox_host:
        print(f"  Knox host: {knox_host}")
        success = service_utils.start_demo_ldap(knox_host)
        if not success:
            print("  Warning: Failed to start Demo LDAP (may already be running)")
    else:
        print("  Warning: Could not find Knox host for Demo LDAP")
    
    print("\n[Step 0] Complete")

