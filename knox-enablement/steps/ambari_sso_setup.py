"""
Step: Configure Ambari SSO with Knox.
Uses ambari-server setup-sso CLI with all flags for non-interactive setup.
"""

from modules import get_ambari_state, SSHClient
from modules.service_utils import ServiceUtils
from modules.knox_state import get_knox_state
from steps.base import get_ambari_configs
from steps import export_knox_cert
from config.settings import AmbariConfig


def run():
    """
    Configure Ambari SSO authentication with Knox.
    
    This step:
    1. Gets the Ambari server host
    2. Builds the Knox SSO provider URL
    3. Gets/exports the Knox certificate
    4. Writes certificate to Ambari server (if needed)
    5. Runs ambari-server setup-sso with all required flags
    
    Idempotent: Can be run multiple times to reconfigure SSO.
    """
    print("\n[Step 6] Configuring Ambari SSO")
    print("=" * 60)
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    knox_state = get_knox_state()
    
    # =========================================================================
    # GATHER INPUTS
    # =========================================================================
    print("\n[Step 6.1] Gathering required inputs...")
    
    # Get Knox certificate from state, or export it if not available
    knox_cert_pem = knox_state.knox_cert_pem
    if not knox_cert_pem:
        print("  Knox certificate not in state, exporting now...")
        export_knox_cert.run()
        knox_cert_pem = knox_state.knox_cert_pem
        
        if not knox_cert_pem:
            print("  ✗ ERROR: Failed to export Knox certificate!")
            raise RuntimeError("Failed to export Knox certificate")
    
    print(f"  ✓ Knox certificate available ({len(knox_cert_pem)} bytes)")
    
    # Get Knox host for SSO URL
    knox_host = knox_state.knox_host
    if not knox_host:
        print("  Knox host not in state, fetching from Ambari...")
        knox_host = service_utils.get_component_host("KNOX", "KNOX_GATEWAY")
    
    if not knox_host:
        print("  ✗ ERROR: Could not determine Knox host!")
        raise RuntimeError("Could not determine Knox host")
    print(f"  ✓ Knox host: {knox_host}")
    
    # Get Ambari server host
    ambari_host = service_utils.get_ambari_server_host()
    print(f"  ✓ Ambari server host: {ambari_host}")
    
    # Build Knox SSO provider URL
    sso_provider_url = f"https://{knox_host}:8443/gateway/knoxsso/api/v1/websso"
    print(f"  ✓ SSO Provider URL: {sso_provider_url}")
    
    # =========================================================================
    # DETERMINE CERTIFICATE PATH
    # =========================================================================
    print(f"\n[Step 6.2] Determining certificate location...")
    
    # Check if Knox and Ambari are on the same host
    same_host = (knox_host == ambari_host)
    knox_cert_path = knox_state.knox_cert_path
    
    if same_host and knox_cert_path:
        # Knox and Ambari on same host - use existing cert path
        cert_file_path = knox_cert_path
        print(f"  ✓ Knox and Ambari on same host ({ambari_host})")
        print(f"  ✓ Using existing cert: {cert_file_path}")
        need_to_write_cert = False
    else:
        # Different hosts - need to write cert to Ambari server
        cert_file_path = "/etc/ambari-server/conf/knox-sso-cert.pem"
        print(f"  Knox host: {knox_host}")
        print(f"  Ambari host: {ambari_host}")
        print(f"  → Will write cert to: {cert_file_path}")
        need_to_write_cert = True
    
    # =========================================================================
    # CONNECT AND CONFIGURE
    # =========================================================================
    print(f"\n[Step 6.3] Connecting to Ambari server: {ambari_host}")
    
    with SSHClient(host=ambari_host) as ssh:
        # =====================================================================
        # WRITE CERTIFICATE FILE (if needed)
        # =====================================================================
        if need_to_write_cert:
            print(f"\n[Step 6.4] Writing certificate to Ambari server...")
            print(f"  Path: {cert_file_path}")
            
            # Use cat with heredoc to write cert
            write_cert_cmd = f"cat << 'EOF' | sudo tee {cert_file_path} > /dev/null\n{knox_cert_pem}\nEOF"
            
            exit_code, stdout, stderr = ssh.execute(
                write_cert_cmd,
                raise_on_error=False
            )
            
            if exit_code != 0:
                print(f"  ✗ ERROR: Failed to write certificate file")
                print(f"  STDERR: {stderr}")
                raise RuntimeError(f"Failed to write certificate to {cert_file_path}")
            
            # Verify file was written
            exit_code, stdout, stderr = ssh.execute_sudo(f"cat {cert_file_path}", raise_on_error=False)
            if exit_code == 0 and "BEGIN CERTIFICATE" in stdout:
                print(f"  ✓ Certificate written successfully ({len(stdout)} bytes)")
            else:
                print(f"  ✗ ERROR: Certificate file verification failed")
                raise RuntimeError("Certificate file verification failed")
        else:
            print(f"\n[Step 6.4] Using existing certificate file...")
            print(f"  Path: {cert_file_path}")
        
        # =====================================================================
        # RUN AMBARI-SERVER SETUP-SSO
        # =====================================================================
        print(f"\n[Step 6.5] Running ambari-server setup-sso...")
        
        # Build the setup-sso command with all flags
        sso_cmd = (
            f"ambari-server setup-sso "
            f"--sso-enabled=true "
            f"--sso-enabled-ambari=true "
            f"--sso-manage-services=true "
            f"--sso-enabled-services=* "
            f"--sso-provider-url={sso_provider_url} "
            f"--sso-public-cert-file={cert_file_path} "
            f"--sso-jwt-cookie-name=hadoop-jwt "
            f"--sso-jwt-audience-list= "
            f"--ambari-admin-username={AmbariConfig.USERNAME} "
            f"--ambari-admin-password={AmbariConfig.PASSWORD}"
        )
        
        # Log the command (mask password)
        masked_cmd = sso_cmd.replace(AmbariConfig.PASSWORD, "****")
        print(f"\n  Command: {masked_cmd}")
        
        # Execute the command
        print(f"\n  Executing setup-sso...")
        exit_code, stdout, stderr = ssh.execute_sudo(
            sso_cmd,
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
            print(f"\n  ✗ ERROR: setup-sso command failed!")
            raise RuntimeError(f"ambari-server setup-sso failed with exit code {exit_code}")
        
        # Check for success message
        if "completed successfully" in stdout.lower():
            print(f"\n  ✓ setup-sso completed successfully!")
        else:
            print(f"\n  ⚠ Command finished but success message not found. Please verify.")
        
        # =====================================================================
        # VERIFY CONFIGURATION
        # =====================================================================
        print(f"\n[Step 6.6] Verifying configuration...")
        
        exit_code, stdout, stderr = ssh.execute_sudo(
            "grep -E 'authentication.jwt|ambari.sso' /etc/ambari-server/conf/ambari.properties",
            raise_on_error=False
        )
        
        print("\n  Current SSO settings in ambari.properties:")
        print("-" * 60)
        if stdout:
            for line in stdout.strip().split('\n'):
                print(f"  {line}")
        print("-" * 60)
        
        # =====================================================================
        # RESULT
        # =====================================================================
        print("\n[Step 6.7] Result")
        print("=" * 60)
        print("  ✓ SSO configuration completed!")
        print(f"  ✓ SSO enabled: true")
        print(f"  ✓ SSO enabled for Ambari: true")
        print(f"  ✓ SSO manage services: true")
        print(f"  ✓ SSO enabled services: * (all)")
        print(f"  ✓ Provider URL: {sso_provider_url}")
        print(f"  ✓ Certificate: {cert_file_path}")
        print(f"  ✓ Cookie name: hadoop-jwt")
        print("")
        print("  Note: Ambari server restart is required to apply changes.")
        print("        This will be done after LDAP configuration is complete.")
    
    print("\n[Step 6] Complete")
    print("=" * 60)
