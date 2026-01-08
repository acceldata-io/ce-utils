"""
Step: Configure Ambari LDAP with Knox Demo LDAP.
Uses ambari-server setup-ldap CLI with all flags for non-interactive setup.
"""

from modules import get_ambari_state, SSHClient
from modules.service_utils import ServiceUtils
from modules.knox_state import get_knox_state
from steps.base import get_ambari_configs
from config.settings import AmbariConfig


def run():
    """
    Configure Ambari LDAP authentication with Knox Demo LDAP.
    
    This step:
    1. Gets the Knox host (where Demo LDAP runs)
    2. Runs ambari-server setup-ldap with all required flags
    3. Does NOT restart Ambari (caller should restart after all config)
    
    Knox Demo LDAP runs on port 33389.
    
    Idempotent: Can be run multiple times to reconfigure LDAP.
    """
    print("\n[Step 7] Configuring Ambari LDAP")
    print("=" * 60)
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    knox_state = get_knox_state()
    
    # =========================================================================
    # GET KNOX HOST (where Demo LDAP runs)
    # =========================================================================
    print("\n[Step 7.1] Getting Knox host (Demo LDAP location)...")
    
    knox_host = knox_state.knox_host
    if not knox_host:
        print("  Knox host not in state, fetching from Ambari...")
        knox_host = service_utils.get_component_host("KNOX", "KNOX_GATEWAY")
    
    if not knox_host:
        print("  ✗ ERROR: Could not determine Knox host!")
        raise RuntimeError("Could not determine Knox host")
    
    print(f"  ✓ Knox host: {knox_host}")
    
    # Demo LDAP settings
    ldap_port = "33389"
    ldap_url = f"{knox_host}:{ldap_port}"
    print(f"  ✓ LDAP URL: {ldap_url}")
    
    # Get Ambari server host
    ambari_host = service_utils.get_ambari_server_host()
    print(f"  ✓ Ambari server host: {ambari_host}")
    
    # =========================================================================
    # LDAP CONFIGURATION VALUES
    # =========================================================================
    print("\n[Step 7.2] LDAP configuration for Knox Demo LDAP...")
    
    # Knox Demo LDAP configuration
    ldap_config = {
        "ldap_url": ldap_url,
        "ldap_ssl": "false",
        "ldap_type": "Generic",
        "ldap_user_class": "person",
        "ldap_user_attr": "uid",
        "ldap_group_class": "groupofnames",
        "ldap_group_attr": "cn",
        "ldap_member_attr": "member",
        "ldap_dn": "dn",
        "ldap_base_dn": "dc=hadoop,dc=apache,dc=org",
        "ldap_manager_dn": "uid=admin,ou=people,dc=hadoop,dc=apache,dc=org",
        "ldap_manager_password": "admin-password",
        "ldap_referral": "follow",
        "ldap_bind_anonym": "false",
        "ldap_sync_collision": "convert",
        "ldap_force_lowercase": "true",
        "ldap_pagination": "true",
    }
    
    print("\n  LDAP Configuration:")
    for key, value in ldap_config.items():
        if "password" in key.lower():
            print(f"    {key}: ****")
        else:
            print(f"    {key}: {value}")
    
    # =========================================================================
    # CONNECT AND RUN SETUP-LDAP
    # =========================================================================
    print(f"\n[Step 7.3] Connecting to Ambari server: {ambari_host}")
    
    with SSHClient(host=ambari_host) as ssh:
        # =====================================================================
        # RUN AMBARI-SERVER SETUP-LDAP
        # =====================================================================
        print(f"\n[Step 7.4] Running ambari-server setup-ldap...")
        
        # Build the setup-ldap command with all flags
        # Explicitly pass empty values for optional secondary LDAP to avoid prompts
        ldap_cmd = (
            f"ambari-server setup-ldap "
            f"--ldap-url={ldap_config['ldap_url']} "
            f"--ldap-secondary-host={knox_host} "
            f"--ldap-secondary-port={ldap_port} "
            f"--ldap-ssl={ldap_config['ldap_ssl']} "
            f"--ldap-type={ldap_config['ldap_type']} "
            f"--ldap-user-class={ldap_config['ldap_user_class']} "
            f"--ldap-user-attr={ldap_config['ldap_user_attr']} "
            f"--ldap-group-class={ldap_config['ldap_group_class']} "
            f"--ldap-group-attr={ldap_config['ldap_group_attr']} "
            f"--ldap-member-attr={ldap_config['ldap_member_attr']} "
            f"--ldap-dn={ldap_config['ldap_dn']} "
            f"--ldap-base-dn={ldap_config['ldap_base_dn']} "
            f"--ldap-manager-dn=\"{ldap_config['ldap_manager_dn']}\" "
            f"--ldap-manager-password=\"{ldap_config['ldap_manager_password']}\" "
            f"--ldap-referral={ldap_config['ldap_referral']} "
            f"--ldap-bind-anonym={ldap_config['ldap_bind_anonym']} "
            f"--ldap-sync-username-collisions-behavior={ldap_config['ldap_sync_collision']} "
            f"--ldap-force-lowercase-usernames={ldap_config['ldap_force_lowercase']} "
            f"--ldap-pagination-enabled={ldap_config['ldap_pagination']} "
            f"--ldap-force-setup "
            f"--ldap-save-settings "
            f"--ambari-admin-username={AmbariConfig.USERNAME} "
            f"--ambari-admin-password={AmbariConfig.PASSWORD}"
        )
        
        # Log the command (mask passwords)
        masked_cmd = ldap_cmd.replace(ldap_config['ldap_manager_password'], "****")
        masked_cmd = masked_cmd.replace(AmbariConfig.PASSWORD, "****")
        print(f"\n  Command:\n  {masked_cmd}")
        
        # Execute the command
        print(f"\n  Executing setup-ldap...")
        exit_code, stdout, stderr = ssh.execute_sudo(
            ldap_cmd,
            timeout=120,
            raise_on_error=False
        )
        
        # Log output
        print(f"\n  Exit code: {exit_code}")
        if stdout:
            print(f"\n  STDOUT:")
            print("-" * 60)
            for line in stdout.strip().split('\n'):
                print(f"  {line}")
            print("-" * 60)
        
        if stderr:
            print(f"\n  STDERR:")
            print("-" * 60)
            for line in stderr.strip().split('\n'):
                print(f"  {line}")
            print("-" * 60)
        
        if exit_code != 0:
            print(f"\n  ✗ ERROR: setup-ldap command failed!")
            raise RuntimeError(f"ambari-server setup-ldap failed with exit code {exit_code}")
        
        # Check for success message
        if "completed successfully" in stdout.lower():
            print(f"\n  ✓ setup-ldap completed successfully!")
        else:
            print(f"\n  ⚠ Command finished but success message not found. Please verify.")
        
        # =====================================================================
        # SYNC LDAP USERS AND GROUPS
        # =====================================================================
        print(f"\n[Step 7.5] Syncing LDAP users and groups...")
        
        sync_cmd = (
            f"ambari-server sync-ldap --all "
            f"--ldap-sync-admin-name={AmbariConfig.USERNAME} "
            f"--ldap-sync-admin-password={AmbariConfig.PASSWORD}"
        )
        
        # Log command (mask password)
        masked_sync_cmd = sync_cmd.replace(AmbariConfig.PASSWORD, "****")
        print(f"\n  Command: {masked_sync_cmd}")
        
        print(f"\n  Executing sync-ldap...")
        exit_code, stdout, stderr = ssh.execute_sudo(
            sync_cmd,
            timeout=120,
            raise_on_error=False
        )
        
        # Log output
        print(f"\n  Exit code: {exit_code}")
        if stdout:
            print(f"\n  STDOUT:")
            print("-" * 60)
            for line in stdout.strip().split('\n'):
                print(f"  {line}")
            print("-" * 60)
        
        if stderr:
            print(f"\n  STDERR:")
            print("-" * 60)
            for line in stderr.strip().split('\n'):
                print(f"  {line}")
            print("-" * 60)
        
        if exit_code != 0:
            print(f"\n  ✗ ERROR: sync-ldap command failed!")
            raise RuntimeError(f"ambari-server sync-ldap failed with exit code {exit_code}")
        
        if "completed successfully" in stdout.lower():
            print(f"\n  ✓ sync-ldap completed successfully!")
        else:
            print(f"\n  ⚠ Command finished but success message not found. Please verify.")
        
        # =====================================================================
        # VERIFY CONFIGURATION
        # =====================================================================
        print(f"\n[Step 7.6] Verifying configuration...")
        
        exit_code, stdout, stderr = ssh.execute_sudo(
            "grep -E '^(ambari.ldap|authentication.ldap|client.security)' /etc/ambari-server/conf/ambari.properties",
            raise_on_error=False
        )
        
        print("\n  Current LDAP settings in ambari.properties:")
        print("-" * 60)
        if stdout:
            for line in stdout.strip().split('\n'):
                # Mask password in output
                if "password" in line.lower():
                    key_part = line.split('=')[0]
                    print(f"  {key_part}=*****")
                else:
                    print(f"  {line}")
        print("-" * 60)
        
        # =====================================================================
        # RESULT
        # =====================================================================
        print("\n[Step 7.7] Result")
        print("=" * 60)
        print("  ✓ LDAP configuration completed!")
        print(f"  ✓ LDAP Server: {ldap_url}")
        print(f"  ✓ Base DN: {ldap_config['ldap_base_dn']}")
        print(f"  ✓ Manager DN: {ldap_config['ldap_manager_dn']}")
        print(f"  ✓ Force setup: enabled")
        print(f"  ✓ Save settings: enabled")
        print("")
        print("  Note: Ambari server restart is required to apply changes.")
        print("        This will be done after all configuration is complete.")
    
    print("\n[Step 7] Complete")
    print("=" * 60)
