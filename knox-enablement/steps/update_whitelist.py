"""
Step: Update Knox gateway dispatch whitelist.
Extracts domain from cluster hostname and creates a regex pattern to whitelist all hosts in that domain.
"""

from steps.base import get_ambari_configs
from modules import get_ambari_state
from modules.service_utils import ServiceUtils


class WhitelistUpdater:
    """Updates Knox gateway dispatch whitelist based on cluster domain."""
    
    def __init__(self, service_utils: ServiceUtils):
        self.service_utils = service_utils
    
    def extract_domain(self, hostname: str) -> str:
        """
        Extract domain from hostname by removing the first part.
        
        Examples:
            ambari-server.ubuntu.ce -> ubuntu.ce
            node1.cluster.example.com -> cluster.example.com
            host-0.myapp.namespace.svc.cluster.local -> myapp.namespace.svc.cluster.local
        """
        parts = hostname.split('.')
        if len(parts) > 1:
            # Remove the first part (hostname) and keep the domain
            domain = '.'.join(parts[1:])
            return domain
        return hostname
    
    def escape_regex(self, text: str) -> str:
        """Escape special regex characters in the domain."""
        # Escape dots for regex
        return text.replace('.', r'\.')
    
    def build_whitelist_regex(self, domain: str) -> str:
        """
        Build the whitelist regex pattern for the domain.
        
        Pattern: ^https?:\/\/(.+\.domain\.escaped):[0-9]+\/?.*$
        """
        escaped_domain = self.escape_regex(domain)
        pattern = f"^https?:\\/\\/(.+\\.{escaped_domain}):[0-9]+\\/?.*$"
        return pattern
    
    def update_whitelist(self, pattern: str) -> None:
        """Update the gateway.dispatch.whitelist in gateway-site config."""
        configs = get_ambari_configs()
        
        print("  Updating gateway.dispatch.whitelist...")
        configs.set_property(
            "gateway-site",
            "gateway.dispatch.whitelist",
            pattern,
            version_note="[knox-enablement] Set dispatch whitelist for cluster domain"
        )


def run():
    """
    Update Knox gateway dispatch whitelist with cluster domain pattern.
    
    This step:
    1. Gets the Ambari server hostname
    2. Extracts the domain (removes first part of hostname)
    3. Builds a regex pattern to match all hosts in that domain
    4. Updates gateway.dispatch.whitelist in gateway-site config
    
    Note: Knox restart is handled by the final restart_services step.
    
    Idempotent: Safe to run multiple times.
    """
    print("\n[Step 3] Updating Knox Gateway Dispatch Whitelist")
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    updater = WhitelistUpdater(service_utils)
    
    # Get Ambari server hostname
    hostname = service_utils.get_ambari_server_host()
    print(f"  Ambari server hostname: {hostname}")
    
    # Extract domain
    domain = updater.extract_domain(hostname)
    print(f"  Extracted domain: {domain}")
    
    # Build whitelist pattern
    pattern = updater.build_whitelist_regex(domain)
    print(f"  Whitelist pattern: {pattern}")
    
    # Update config
    updater.update_whitelist(pattern)
    
    print("\n[Step 3] Complete")

