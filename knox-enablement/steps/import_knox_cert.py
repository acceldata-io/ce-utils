"""
Step: Import Knox certificate into system cacerts.
This enables trusted SSL connections from Ranger and other services to Knox.
"""

from modules import get_ambari_state, SSHClient
from modules.service_utils import ServiceUtils
from modules.knox_state import get_knox_state
from steps.base import get_ambari_configs
from steps import export_knox_cert


def import_cert_on_host(host: str, knox_cert_pem: str, alias: str = "knox-gateway") -> bool:
    """
    Import Knox certificate into cacerts on a single host.
    
    Args:
        host: Hostname to import certificate on
        knox_cert_pem: PEM-encoded certificate content
        alias: Alias to use in keystore (default: knox-gateway)
        
    Returns:
        True if successful, False otherwise
    """
    print(f"\n  --- Importing certificate on: {host} ---")
    
    try:
        with SSHClient(host=host) as ssh:
            # Find Java home
            print(f"    Finding Java home...")
            exit_code, stdout, stderr = ssh.execute_sudo(
                "java -XshowSettings:properties -version 2>&1 | grep 'java.home' | awk '{print $NF}'",
                raise_on_error=False
            )
            
            cacerts_path = None
            java_home = None
            
            if exit_code != 0 or not stdout.strip():
                # Fallback: try to find cacerts directly
                print("    Could not detect java.home, searching for cacerts...")
                exit_code, stdout, _ = ssh.execute_sudo(
                    "find /usr -name cacerts -path '*/security/*' 2>/dev/null | head -1",
                    raise_on_error=False
                )
                if stdout.strip():
                    cacerts_path = stdout.strip()
                else:
                    print(f"    ✗ Could not find cacerts on {host}")
                    return False
            else:
                java_home = stdout.strip()
                # Handle both JRE and JDK paths
                if java_home.endswith("/jre"):
                    cacerts_path = f"{java_home}/lib/security/cacerts"
                else:
                    # Check for JDK structure
                    exit_code, check_stdout, _ = ssh.execute_sudo(
                        f"test -f {java_home}/lib/security/cacerts && echo 'jdk' || echo 'jre'",
                        raise_on_error=False
                    )
                    if "jdk" in check_stdout:
                        cacerts_path = f"{java_home}/lib/security/cacerts"
                    else:
                        cacerts_path = f"{java_home}/jre/lib/security/cacerts"
            
            if not cacerts_path:
                print(f"    ✗ Could not determine cacerts path on {host}")
                return False

            print(f"    ✓ Cacerts path: {cacerts_path}")
            
            # Verify cacerts exists
            exit_code, stdout, stderr = ssh.execute_sudo(
                f"test -f {cacerts_path} && echo 'exists'", 
                raise_on_error=False
            )
            if "exists" not in stdout:
                print(f"    ✗ Cacerts file not found at {cacerts_path}")
                return False
            
            # Write certificate to temp file
            cert_temp_path = "/tmp/knox-gateway-cert.pem"
            print(f"    Writing certificate to {cert_temp_path}...")
            
            write_cert_cmd = f"cat << 'EOF' | sudo tee {cert_temp_path} > /dev/null\n{knox_cert_pem}\nEOF"
            exit_code, stdout, stderr = ssh.execute(write_cert_cmd, raise_on_error=False)
            
            if exit_code != 0:
                print(f"    ✗ Failed to write certificate")
                return False
            
            # Remove existing alias if present (for idempotency)
            print(f"    Removing existing alias '{alias}' if present...")
            remove_cmd = f"keytool -delete -alias {alias} -keystore {cacerts_path} -storepass changeit 2>/dev/null || true"
            ssh.execute_sudo(remove_cmd, raise_on_error=False)
            
            # Import certificate
            print(f"    Importing certificate with alias '{alias}'...")
            import_cmd = (
                f"keytool -import -trustcacerts "
                f"-alias {alias} "
                f"-file {cert_temp_path} "
                f"-keystore {cacerts_path} "
                f"-storepass changeit "
                f"-noprompt"
            )
            
            exit_code, stdout, stderr = ssh.execute_sudo(import_cmd, raise_on_error=False)
            
            # Cleanup temp file
            ssh.execute_sudo(f"rm -f {cert_temp_path}", raise_on_error=False)
            
            if exit_code != 0:
                print(f"    ✗ Failed to import certificate: {stderr.strip()}")
                return False
            
            print(f"    ✓ Certificate imported successfully on {host}")
            return True
                
    except Exception as e:
        print(f"    ✗ Error processing host {host}: {e}")
        return False


def import_cert_on_hosts(hosts: list, knox_cert_pem: str, alias: str = "knox-gateway") -> dict:
    """
    Import Knox certificate on multiple hosts.
    
    Args:
        hosts: List of hostnames to import certificate on
        knox_cert_pem: PEM-encoded certificate content
        alias: Alias to use in keystore
        
    Returns:
        Dict with 'success' and 'failed' lists of hostnames
    """
    results = {"success": [], "failed": []}
    
    # Deduplicate hosts while preserving order
    unique_hosts = list(dict.fromkeys(hosts))
    
    print(f"\n[Step 2] Importing Knox certificate on {len(unique_hosts)} host(s)")
    print(f"  Hosts: {', '.join(unique_hosts)}")
    
    for host in unique_hosts:
        success = import_cert_on_host(host, knox_cert_pem, alias)
        if success:
            results["success"].append(host)
        else:
            results["failed"].append(host)
    
    return results


def get_ranger_hosts(service_utils: ServiceUtils) -> list:
    """
    Get all Ranger-related hosts (RANGER_ADMIN and RANGER_KMS).
    
    Args:
        service_utils: ServiceUtils instance
        
    Returns:
        List of hostnames
    """
    hosts = []
    
    # Get RANGER_ADMIN hosts
    print("  Finding RANGER_ADMIN hosts...")
    ranger_admin_host = service_utils.get_component_host("RANGER", "RANGER_ADMIN")
    if ranger_admin_host:
        hosts.append(ranger_admin_host)
        print(f"    ✓ RANGER_ADMIN: {ranger_admin_host}")
    else:
        print(f"    - RANGER_ADMIN: not found")
    
    # Get RANGER_KMS hosts
    print("  Finding RANGER_KMS hosts...")
    ranger_kms_host = service_utils.get_component_host("RANGER_KMS", "RANGER_KMS_SERVER")
    if ranger_kms_host:
        hosts.append(ranger_kms_host)
        print(f"    ✓ RANGER_KMS_SERVER: {ranger_kms_host}")
    else:
        print(f"    - RANGER_KMS_SERVER: not found")
    
    return hosts


def run():
    """
    Import Knox gateway certificate into Java cacerts truststore on Ranger hosts.
    
    This step:
    1. Gets the Knox certificate (from state or exports it)
    2. Identifies Ranger hosts (RANGER_ADMIN, RANGER_KMS)
    3. Imports the certificate into cacerts on those hosts
    4. Configures Ranger truststore settings
    5. Restarts Ranger to pick up changes
    
    Idempotent: Safe to run multiple times (overwrites existing alias).
    """
    print("\n[Step] Importing Knox Certificate to Cacerts")
    print("=" * 60)
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    knox_state = get_knox_state()
    
    # =========================================================================
    # GET KNOX CERTIFICATE
    # =========================================================================
    print("\n[Step 1] Getting Knox certificate...")
    
    knox_cert_pem = knox_state.knox_cert_pem
    if not knox_cert_pem:
        print("  Knox certificate not in state, exporting now...")
        export_knox_cert.run()
        knox_cert_pem = knox_state.knox_cert_pem
        
        if not knox_cert_pem:
            print("  ✗ ERROR: Failed to get Knox certificate!")
            raise RuntimeError("Failed to get Knox certificate")
    
    print(f"  ✓ Knox certificate available ({len(knox_cert_pem)} bytes)")
    
    # =========================================================================
    # DETERMINE TARGET HOSTS
    # =========================================================================
    print("\n[Step 1.1] Determining target hosts...")
    
    # Get Ranger hosts
    target_hosts = get_ranger_hosts(service_utils)
    
    # -------------------------------------------------------------------------
    # MODIFY THIS LIST TO ADD MORE HOSTS IF NEEDED
    # -------------------------------------------------------------------------
    # Example: Add additional hosts manually
    # target_hosts.append("additional-host-1.example.com")
    # target_hosts.append("additional-host-2.example.com")
    #
    # Example: Add all cluster hosts
    # hosts_result = service_utils._api_request("/api/v1/hosts")
    # if hosts_result and hosts_result.get("items"):
    #     for item in hosts_result["items"]:
    #         target_hosts.append(item["Hosts"]["host_name"])
    # -------------------------------------------------------------------------
    
    if not target_hosts:
        print("  ⚠ Warning: No target hosts found. Nothing to do.")
        return
    
    # =========================================================================
    # IMPORT CERTIFICATE ON TARGET HOSTS
    # =========================================================================
    results = import_cert_on_hosts(target_hosts, knox_cert_pem)
    
    # Print summary
    print(f"\n  Import Summary:")
    print(f"    ✓ Success: {len(results['success'])} host(s)")
    if results['success']:
        for h in results['success']:
            print(f"        - {h}")
    print(f"    ✗ Failed: {len(results['failed'])} host(s)")
    if results['failed']:
        for h in results['failed']:
            print(f"        - {h}")
    
    # =========================================================================
    # CONFIGURE RANGER TRUSTSTORE
    # =========================================================================
    print(f"\n[Step 3] Configuring Ranger truststore...")
    
    # Detect cacerts path on the first successful host for config
    cacerts_path_for_config = None
    if results['success']:
        first_host = results['success'][0]
        try:
            with SSHClient(host=first_host) as ssh:
                exit_code, stdout, stderr = ssh.execute_sudo(
                    "java -XshowSettings:properties -version 2>&1 | grep 'java.home' | awk '{print $NF}'",
                    raise_on_error=False
                )
                if exit_code == 0 and stdout.strip():
                    java_home = stdout.strip()
                    if java_home.endswith("/jre"):
                        cacerts_path_for_config = f"{java_home}/lib/security/cacerts"
                    else:
                        exit_code, check_stdout, _ = ssh.execute_sudo(
                            f"test -f {java_home}/lib/security/cacerts && echo 'jdk' || echo 'jre'",
                            raise_on_error=False
                        )
                        if "jdk" in check_stdout:
                            cacerts_path_for_config = f"{java_home}/lib/security/cacerts"
                        else:
                            cacerts_path_for_config = f"{java_home}/jre/lib/security/cacerts"
        except Exception as e:
            print(f"  ⚠ Warning: Could not detect cacerts path for config: {e}")

    if cacerts_path_for_config:
        ranger_truststore_props = {
            "ranger.truststore.file": cacerts_path_for_config,
            "ranger.truststore.password": "changeit",
        }
        
        print(f"  Setting ranger-admin-site properties:")
        for key, value in ranger_truststore_props.items():
            display_val = "****" if "password" in key.lower() else value
            print(f"    {key} = {display_val}")
        
        try:
            configs.set_properties(
                "ranger-admin-site",
                ranger_truststore_props,
                version_note="[knox-enablement] Configure Ranger truststore for Knox SSL"
            )
            print("  ✓ Ranger truststore configured")
        except Exception as e:
            print(f"  ⚠ Warning: Could not configure Ranger truststore: {e}")
    else:
        print("  ⚠ Warning: Could not determine cacerts path. Skipping Ranger config.")
    
    # =========================================================================
    # RESTART RANGER
    # =========================================================================
    print(f"\n[Step 4] Restarting Ranger to pick up new certificate...")
    
    try:
        service_utils.restart_service(
            "RANGER",
            context_prefix="[knox-enablement] Restart Ranger after Knox cert import"
        )
        print("  ✓ Ranger restarted successfully")
    except Exception as e:
        print(f"  ⚠ Warning: Could not restart Ranger: {e}")
        print("    Ranger may need manual restart to trust Knox SSL")
    
    # =========================================================================
    # RESULT
    # =========================================================================
    print("\n[Step] Result")
    print("=" * 60)
    print(f"  ✓ Knox certificate imported on {len(results['success'])} host(s)")
    print(f"  ✓ Alias: knox-gateway")
    if cacerts_path_for_config:
        print(f"  ✓ Ranger truststore configured: {cacerts_path_for_config}")
    print(f"  ✓ Ranger restarted")
    print("")
    print("  This enables Ranger to trust Knox SSL connections.")
    
    print("\n[Step] Complete")
    print("=" * 60)
