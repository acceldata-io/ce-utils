"""
Global state manager for Ambari cluster information.
Fetches values once from API and caches them for reuse.
"""

import urllib.request
import urllib.error
import ssl
import json
import base64
from typing import Optional
from config.settings import AmbariConfig


class AmbariState:
    """
    Singleton-like class to cache Ambari cluster state.
    Fetches values from API once and stores them globally.
    """
    
    _instance: Optional['AmbariState'] = None
    _initialized: bool = False
    
    # Cached values
    _cluster_name: Optional[str] = None
    _hosts: Optional[list] = None
    _services: Optional[list] = None
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        if AmbariState._initialized:
            return
        AmbariState._initialized = True
    
    def _api_request(self, endpoint: str) -> dict:
        """Make GET request to Ambari API."""
        url = f"{AmbariConfig.PROTOCOL}://{AmbariConfig.HOST}:{AmbariConfig.PORT}{endpoint}"
        
        auth = base64.encodebytes(
            f'{AmbariConfig.USERNAME}:{AmbariConfig.PASSWORD}'.encode()
        ).decode().replace('\n', '')
        
        request = urllib.request.Request(url)
        request.add_header('Authorization', f'Basic {auth}')
        request.add_header('X-Requested-By', 'ambari')
        
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        
        response = urllib.request.urlopen(request, context=ctx)
        body = response.read().decode('utf-8')
        return json.loads(body) if body else {}
    
    @property
    def cluster_name(self) -> str:
        """Get cluster name (fetched once from API)."""
        if self._cluster_name is None:
            print("[AmbariState] Fetching cluster name from API...")
            result = self._api_request("/api/v1/clusters")
            items = result.get("items", [])
            if not items:
                raise RuntimeError("No clusters found in Ambari")
            # Use the first cluster
            self._cluster_name = items[0]["Clusters"]["cluster_name"]
            print(f"[AmbariState] Cluster name: {self._cluster_name}")
        return self._cluster_name
    
    @property
    def hosts(self) -> list:
        """Get list of hosts in the cluster (fetched once from API)."""
        if self._hosts is None:
            print("[AmbariState] Fetching hosts from API...")
            endpoint = f"/api/v1/clusters/{self.cluster_name}/hosts"
            result = self._api_request(endpoint)
            self._hosts = [
                item["Hosts"]["host_name"] 
                for item in result.get("items", [])
            ]
            print(f"[AmbariState] Found {len(self._hosts)} hosts")
        return self._hosts
    
    @property
    def first_host(self) -> str:
        """Get the first host in the cluster."""
        hosts = self.hosts
        if not hosts:
            raise RuntimeError("No hosts found in cluster")
        return hosts[0]
    
    @property
    def services(self) -> list:
        """Get list of installed services (fetched once from API)."""
        if self._services is None:
            print("[AmbariState] Fetching services from API...")
            endpoint = f"/api/v1/clusters/{self.cluster_name}/services"
            result = self._api_request(endpoint)
            self._services = [
                item["ServiceInfo"]["service_name"]
                for item in result.get("items", [])
            ]
            print(f"[AmbariState] Found {len(self._services)} services")
        return self._services
    
    def is_service_installed(self, service_name: str) -> bool:
        """Check if a service is installed."""
        return service_name in self.services
    
    def refresh(self):
        """Clear cached values to force re-fetch on next access."""
        self._cluster_name = None
        self._hosts = None
        self._services = None
        print("[AmbariState] Cache cleared")


# Global instance for easy access
_state: Optional[AmbariState] = None


def get_ambari_state(refresh: bool = False) -> AmbariState:
    """
    Get the global AmbariState instance.
    
    Args:
        refresh: If True, clears cached values to force re-fetch from API
    """
    global _state
    if _state is None:
        _state = AmbariState()
    elif refresh:
        _state.refresh()
    return _state

