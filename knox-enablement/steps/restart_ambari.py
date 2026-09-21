"""
Step: Restart Ambari server to apply SSO and LDAP configuration.
"""

from modules import get_ambari_state, SSHClient
from modules.service_utils import ServiceUtils
from steps.base import get_ambari_configs


def run():
    """
    Restart Ambari server to apply configuration changes.
    
    This step:
    1. Stops Ambari server
    2. Starts Ambari server
    3. Verifies Ambari is running
    
    Should be run after SSO and LDAP configuration steps.
    
    Idempotent: Safe to run multiple times.
    """
    print("\n[Step 8] Restarting Ambari Server")
    print("=" * 60)
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    
    # Get Ambari server host
    ambari_host = service_utils.get_ambari_server_host()
    print(f"\n  Ambari server host: {ambari_host}")
    
    # =========================================================================
    # RESTART AMBARI
    # =========================================================================
    print(f"\n[Step 8.1] Connecting to Ambari server: {ambari_host}")
    
    with SSHClient(host=ambari_host) as ssh:
        print(f"\n[Step 8.2] Restarting Ambari server...")
        
        success = service_utils.restart_ambari_server(ssh, verify=True)
        
        if not success:
            raise RuntimeError("Failed to restart Ambari server")
    
    # =========================================================================
    # RESULT
    # =========================================================================
    print("\n[Step 8.3] Result")
    print("=" * 60)
    print("  ✓ Ambari server restarted successfully!")
    print("")
    print("  SSO and LDAP configuration has been applied.")
    print("  It may take a minute for Ambari to fully initialize.")
    print("")
    print(f"  Access Ambari at: http://{ambari_host}:8080")
    print("  (You should now be redirected to Knox SSO for login)")
    
    print("\n[Step 8] Complete")
    print("=" * 60)

