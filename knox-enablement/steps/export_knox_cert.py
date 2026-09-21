"""
Step: Export Knox gateway certificate.
Runs knoxcli.sh export-cert on the Knox host and stores the PEM content in state.
"""

import re
from modules import get_ambari_state, SSHClient
from modules.service_utils import ServiceUtils
from modules.knox_state import get_knox_state
from steps.base import get_ambari_configs


def run():
    """
    Export Knox gateway certificate to PEM format.
    
    This step:
    1. Gets the Knox host from Ambari
    2. SSHs to the Knox host
    3. Runs knoxcli.sh export-cert --type PEM
    4. Reads the exported PEM file
    5. Stores the PEM content in KnoxState
    
    Idempotent: Safe to run multiple times (overwrites existing cert).
    """
    print("\n[Step 5] Exporting Knox Gateway Certificate")
    print("=" * 60)
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    knox_state = get_knox_state()
    
    # =========================================================================
    # GET KNOX HOST
    # =========================================================================
    print("\n[Step 5.1] Finding Knox host...")
    
    knox_host = service_utils.get_component_host("KNOX", "KNOX_GATEWAY")
    if not knox_host:
        print("  ✗ ERROR: Could not find Knox host!")
        print("  → Is Knox installed in the cluster?")
        raise RuntimeError("Could not find Knox host")
    
    print(f"  ✓ Knox host: {knox_host}")
    knox_state.knox_host = knox_host
    
    # =========================================================================
    # EXPORT CERTIFICATE
    # =========================================================================
    print(f"\n[Step 5.2] Connecting to Knox host: {knox_host}")
    
    with SSHClient(host=knox_host) as ssh:
        export_cmd = "/usr/odp/current/knox-server/bin/knoxcli.sh export-cert --type PEM"
        
        print(f"\n[Step 5.3] Executing certificate export...")
        print(f"  Host: {knox_host}")
        print(f"  Command: sudo {export_cmd}")
        print("-" * 60)
        
        exit_code, stdout, stderr = ssh.execute_sudo(
            export_cmd,
            raise_on_error=False
        )
        
        # Log full output
        print(f"\n--- EXIT CODE: {exit_code} ---")
        
        if stdout:
            print("\n--- STDOUT ---")
            print(stdout)
        
        if stderr:
            print("\n--- STDERR ---")
            print(stderr)
        
        print("-" * 60)
        
        # Parse the output to get the cert path
        cert_path = None
        output = stdout + stderr
        
        match = re.search(r'exported to:\s*(\S+\.pem)', output)
        if match:
            cert_path = match.group(1)
            print(f"\n  ✓ Certificate exported to: {cert_path}")
        else:
            # Default path based on ODP structure
            cert_path = "/usr/odp/current/knox-server/data/security/keystores/gateway-client-trust.pem"
            print(f"\n  ⚠ Could not parse export path from output")
            print(f"  → Using default path: {cert_path}")
        
        knox_state.knox_cert_path = cert_path
        
        # =====================================================================
        # READ CERTIFICATE CONTENT
        # =====================================================================
        print(f"\n[Step 5.4] Reading certificate file...")
        print(f"  Command: sudo cat {cert_path}")
        
        exit_code, pem_content, stderr = ssh.execute_sudo(
            f"cat {cert_path}",
            raise_on_error=False
        )
        
        if exit_code != 0:
            print(f"\n  ✗ ERROR: Failed to read certificate (exit code {exit_code})")
            if stderr:
                print(f"  STDERR: {stderr}")
            print(f"\n  --- DEBUGGING TIPS ---")
            print(f"  1. SSH to {knox_host} and check:")
            print(f"     - File exists: ls -la {cert_path}")
            print(f"     - Knox keystore: ls -la /usr/odp/current/knox-server/data/security/keystores/")
            print(f"  2. Try exporting manually:")
            print(f"     - ssh {knox_host}")
            print(f"     - sudo {export_cmd}")
            raise RuntimeError(f"Failed to read certificate from {cert_path}")
        
        if not pem_content:
            print(f"\n  ✗ ERROR: Certificate file is empty!")
            raise RuntimeError(f"Certificate file is empty: {cert_path}")
        
        # Store in state
        knox_state.knox_cert_pem = pem_content
        
        # =====================================================================
        # SHOW CERTIFICATE INFO
        # =====================================================================
        print(f"\n[Step 5.5] Certificate Details")
        print("=" * 60)
        print(f"  Path: {cert_path}")
        print(f"  Size: {len(pem_content)} bytes")
        
        lines = pem_content.strip().split('\n')
        print(f"  Lines: {len(lines)}")
        
        if lines:
            print(f"  Header: {lines[0]}")
            print(f"  Footer: {lines[-1]}")
        
        # Validate it looks like a PEM certificate
        if "-----BEGIN CERTIFICATE-----" in pem_content and "-----END CERTIFICATE-----" in pem_content:
            print(f"  Format: ✓ Valid PEM certificate")
        else:
            print(f"  Format: ⚠ WARNING - Does not look like a valid PEM certificate!")
        
        print(f"\n  --- FULL CERTIFICATE ---")
        print(pem_content)
        print("=" * 60)
    
    print("\n[Step 5] Complete")
    print("=" * 60)

