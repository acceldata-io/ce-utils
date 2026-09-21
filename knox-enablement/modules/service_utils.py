"""
Service utilities for starting, stopping, and restarting Ambari services.
Reusable across all steps.
"""

import time
import urllib.request
import urllib.error
import ssl
import json
import base64
from config.settings import AmbariConfig


class ServiceUtils:
    """Manages Ambari service operations (start, stop, restart)."""
    
    def __init__(self, configs, state):
        """
        Initialize ServiceUtils.
        
        Args:
            configs: AmbariConfigs instance
            state: AmbariState instance
        """
        self.configs = configs
        self.state = state
        self.cluster = state.cluster_name
        self._component_hosts_cache = {}
    
    def _api_request(self, endpoint: str, method: str = "GET", data: dict = None) -> dict:
        """Make API request to Ambari."""
        url = f"{AmbariConfig.PROTOCOL}://{AmbariConfig.HOST}:{AmbariConfig.PORT}{endpoint}"
        
        auth = base64.encodebytes(
            f'{AmbariConfig.USERNAME}:{AmbariConfig.PASSWORD}'.encode()
        ).decode().replace('\n', '')
        
        request = urllib.request.Request(url)
        request.add_header('Authorization', f'Basic {auth}')
        request.add_header('X-Requested-By', 'ambari')
        request.add_header('Content-Type', 'application/json')
        
        if data:
            request.data = json.dumps(data).encode('utf-8')
        request.get_method = lambda: method
        
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        try:
            response = urllib.request.urlopen(request, context=ctx)
            body = response.read().decode('utf-8')
            return json.loads(body) if body else {}
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
    
    def get_service_state(self, service_name: str) -> str:
        """Get the current state of a service."""
        endpoint = f"/api/v1/clusters/{self.cluster}/services/{service_name}"
        result = self._api_request(endpoint)
        if result:
            return result.get("ServiceInfo", {}).get("state", "UNKNOWN")
        return None
    
    def stop_service(self, service_name: str, context: str = None) -> int:
        """Stop a service. Returns request ID."""
        ctx = context or f"[knox-enablement] Stop {service_name}"
        print(f"    Stopping {service_name}...")
        
        endpoint = f"/api/v1/clusters/{self.cluster}/services/{service_name}"
        data = {
            "RequestInfo": {"context": ctx},
            "ServiceInfo": {"state": "INSTALLED"}
        }
        result = self._api_request(endpoint, method="PUT", data=data)
        if result and "Requests" in result:
            return result["Requests"]["id"]
        return None
    
    def start_service(self, service_name: str, context: str = None) -> int:
        """Start a service. Returns request ID."""
        ctx = context or f"[knox-enablement] Start {service_name}"
        print(f"    Starting {service_name}...")
        
        endpoint = f"/api/v1/clusters/{self.cluster}/services/{service_name}"
        data = {
            "RequestInfo": {"context": ctx},
            "ServiceInfo": {"state": "STARTED"}
        }
        result = self._api_request(endpoint, method="PUT", data=data)
        if result and "Requests" in result:
            return result["Requests"]["id"]
        return None
    
    def wait_for_request(self, request_id: int, timeout: int = 600) -> bool:
        """Wait for an Ambari request to complete."""
        if not request_id:
            return True
        
        print(f"    Waiting for request {request_id}...")
        endpoint = f"/api/v1/clusters/{self.cluster}/requests/{request_id}"
        
        start_time = time.time()
        last_progress = -1
        while time.time() - start_time < timeout:
            result = self._api_request(endpoint)
            if result:
                status = result.get("Requests", {}).get("request_status")
                progress = result.get("Requests", {}).get("progress_percent", 0)
                
                if progress != last_progress:
                    print(f"      Status: {status}, Progress: {progress}%")
                    last_progress = progress
                
                if status == "COMPLETED":
                    return True
                elif status in ["FAILED", "ABORTED", "TIMEDOUT"]:
                    print(f"    Request failed: {status}")
                    return False
            
            time.sleep(3)
        
        print("    Timeout waiting for request")
        return False
    
    def restart_service(self, service_name: str, context_prefix: str = "[knox-enablement]") -> bool:
        """
        Restart a service (stop then start).
        
        Args:
            service_name: Name of the service (e.g., "KNOX", "HDFS")
            context_prefix: Prefix for the request context
            
        Returns:
            True if restart successful, False otherwise
        """
        print(f"  Restarting {service_name}...")
        
        # Stop
        request_id = self.stop_service(
            service_name, 
            context=f"{context_prefix} Stop {service_name}"
        )
        if request_id:
            if not self.wait_for_request(request_id):
                print(f"  Failed to stop {service_name}")
                return False
        
        # Start
        request_id = self.start_service(
            service_name,
            context=f"{context_prefix} Start {service_name}"
        )
        if request_id:
            if not self.wait_for_request(request_id):
                print(f"  Failed to start {service_name}")
                return False
        
        print(f"  {service_name} restarted successfully.")
        return True
    
    def restart_services(self, service_names: list, context_prefix: str = "[knox-enablement]") -> bool:
        """
        Restart multiple services sequentially.
        
        Args:
            service_names: List of service names to restart
            context_prefix: Prefix for the request context
            
        Returns:
            True if all restarts successful, False otherwise
        """
        all_success = True
        for service_name in service_names:
            success = self.restart_service(service_name, context_prefix)
            if not success:
                all_success = False
        return all_success
    
    def get_component_host(self, service: str, component: str) -> str:
        """Get the host for a specific component."""
        cache_key = f"{service}/{component}"
        if cache_key in self._component_hosts_cache:
            return self._component_hosts_cache[cache_key]
        
        endpoint = f"/api/v1/clusters/{self.cluster}/services/{service}/components/{component}"
        result = self._api_request(endpoint)
        
        host = None
        if result and result.get("host_components"):
            host = result["host_components"][0]["HostRoles"]["host_name"]
        
        self._component_hosts_cache[cache_key] = host
        return host
    
    def get_ambari_server_host(self) -> str:
        """Get the Ambari server hostname from API."""
        endpoint = "/api/v1/services/AMBARI/components/AMBARI_SERVER"
        result = self._api_request(endpoint)
        
        if result and result.get("hostComponents"):
            return result["hostComponents"][0]["RootServiceHostComponents"]["host_name"]
        
        # Fallback: get first host
        endpoint = "/api/v1/hosts"
        result = self._api_request(endpoint)
        if result and result.get("items"):
            return result["items"][0]["Hosts"]["host_name"]
        
        return AmbariConfig.HOST
    
    def start_demo_ldap(self, knox_host: str) -> bool:
        """Start Demo LDAP via custom action."""
        print("  Starting Demo LDAP...")
        endpoint = f"/api/v1/clusters/{self.cluster}/requests"
        data = {
            "RequestInfo": {
                "command": "STARTDEMOLDAP",
                "context": "[knox-enablement] Start Demo LDAP"
            },
            "Requests/resource_filters": [
                {
                    "service_name": "KNOX",
                    "component_name": "KNOX_GATEWAY",
                    "hosts": knox_host
                }
            ]
        }
        result = self._api_request(endpoint, method="POST", data=data)
        if result and "Requests" in result:
            request_id = result["Requests"]["id"]
            return self.wait_for_request(request_id)
        return True  # No request ID means it may already be running
    
    def get_services_requiring_restart(self, service_names: list) -> list:
        """Check which services have stale configs and require restart."""
        endpoint = f"/api/v1/clusters/{self.cluster}/services?fields=ServiceInfo/service_name,ServiceInfo/state"
        result = self._api_request(endpoint)
        
        services_to_restart = []
        if result and result.get("items"):
            for item in result["items"]:
                service_info = item.get("ServiceInfo", {})
                service_name = service_info.get("service_name")
                state = service_info.get("state")
                
                # Only check specified services that are in STARTED state
                if service_name in service_names and state == "STARTED":
                    stale = self._check_service_stale_configs(service_name)
                    if stale:
                        services_to_restart.append(service_name)
        
        return services_to_restart
    
    def _check_service_stale_configs(self, service_name: str) -> bool:
        """Check if a service has any components with stale configs."""
        endpoint = f"/api/v1/clusters/{self.cluster}/services/{service_name}/components?fields=host_components/HostRoles/stale_configs"
        result = self._api_request(endpoint)
        
        if result and result.get("items"):
            for component in result["items"]:
                host_components = component.get("host_components", [])
                for hc in host_components:
                    if hc.get("HostRoles", {}).get("stale_configs", False):
                        return True
        return False
    
    # =========================================================================
    # AMBARI SERVER CLI OPERATIONS (via SSH, not API)
    # =========================================================================
    
    def stop_ambari_server(self, ssh_client) -> bool:
        """
        Stop Ambari server via CLI.
        
        Args:
            ssh_client: Connected SSHClient instance to Ambari server host
            
        Returns:
            True if stopped successfully
        """
        print("  Stopping Ambari server...")
        
        exit_code, stdout, stderr = ssh_client.execute_sudo(
            "ambari-server stop",
            timeout=120,
            raise_on_error=False
        )
        
        print(f"    Exit code: {exit_code}")
        if stdout:
            print(f"    Output: {stdout}")
        if stderr and exit_code != 0:
            print(f"    Stderr: {stderr}")
        
        if exit_code == 0:
            print("  ✓ Ambari server stopped")
            return True
        else:
            print(f"  ⚠ Stop command returned {exit_code} (may already be stopped)")
            return True  # Consider it success if already stopped
    
    def start_ambari_server(self, ssh_client) -> bool:
        """
        Start Ambari server via CLI.
        
        Args:
            ssh_client: Connected SSHClient instance to Ambari server host
            
        Returns:
            True if started successfully
        """
        print("  Starting Ambari server...")
        
        exit_code, stdout, stderr = ssh_client.execute_sudo(
            "ambari-server start",
            timeout=120,
            raise_on_error=False
        )
        
        print(f"    Exit code: {exit_code}")
        if stdout:
            print(f"    Output: {stdout}")
        if stderr and exit_code != 0:
            print(f"    Stderr: {stderr}")
        
        if exit_code == 0:
            print("  ✓ Ambari server started")
            return True
        else:
            print(f"  ✗ ERROR: Failed to start Ambari server")
            return False
    
    def get_ambari_server_status(self, ssh_client) -> str:
        """
        Get Ambari server status via CLI.
        
        Args:
            ssh_client: Connected SSHClient instance to Ambari server host
            
        Returns:
            Status string (e.g., "running", "stopped", "unknown")
        """
        exit_code, stdout, stderr = ssh_client.execute_sudo(
            "ambari-server status",
            timeout=30,
            raise_on_error=False
        )
        
        if "running" in stdout.lower():
            return "running"
        elif "stopped" in stdout.lower() or "not running" in stdout.lower():
            return "stopped"
        else:
            return "unknown"
    
    def restart_ambari_server(self, ssh_client, verify: bool = True) -> bool:
        """
        Restart Ambari server via CLI.
        
        Args:
            ssh_client: Connected SSHClient instance to Ambari server host
            verify: Whether to verify Ambari is running after restart
            
        Returns:
            True if restart successful
        """
        print("  Restarting Ambari server...")
        
        exit_code, stdout, stderr = ssh_client.execute_sudo(
            "ambari-server restart",
            timeout=180,
            raise_on_error=False
        )
        
        print(f"    Exit code: {exit_code}")
        if stdout:
            print(f"    Output: {stdout}")
        if stderr and exit_code != 0:
            print(f"    Stderr: {stderr}")
        
        if exit_code != 0:
            print("  ✗ ERROR: Failed to restart Ambari server")
            return False
        
        print("  ✓ Ambari server restarted")
        
        # Verify
        if verify:
            print("  Verifying Ambari server status...")
            time.sleep(3)  # Give it a moment to fully start
            
            status = self.get_ambari_server_status(ssh_client)
            print(f"    Status: {status}")
            
            if status == "running":
                print("  ✓ Ambari server is running")
            else:
                print("  ⚠ WARNING: Could not verify Ambari is running")
        
        return True

