"""
Step: Update Knox topology configuration.
Replaces hostname placeholders with actual cluster hostnames.
Keeps {{}} Ambari-managed variables as-is.
"""

from pathlib import Path
from steps.base import get_ambari_configs
from modules import get_ambari_state
from modules.service_utils import ServiceUtils
from config.settings import AmbariConfig


class TopologyUpdater:
    """Fetches cluster hostnames and updates Knox topology."""
    
    # HaProvider XML to inject when HDFS HA is enabled
    HA_PROVIDER_XML = """
                <provider>
                    <role>ha</role>
                    <name>HaProvider</name>
                    <enabled>true</enabled>
                    <param>
                        <name>WEBHDFS</name>
                        <value>maxFailoverAttempts=3;failoverSleep=1000;maxRetryAttempts=300;retrySleep=1000;enabled=true</value>
                    </param>
                </provider>
"""
    
    def __init__(self, state, service_utils: ServiceUtils, configs):
        self.state = state
        self.cluster = state.cluster_name
        self.service_utils = service_utils
        self.configs = configs
    
    def get_hostnames(self) -> dict:
        """Gather hostnames needed for topology placeholders."""
        print("  Gathering cluster hostnames...")
        
        # Get hosts for services that use <hostname> placeholder
        
        # YARNUI - ResourceManager host
        rm_host = self.service_utils.get_component_host("YARN", "RESOURCEMANAGER")
        print(f"    ResourceManager (YARNUI): {rm_host}")
        
        # AMBARI - get hostname from API
        ambari_host = self.service_utils.get_ambari_server_host()
        print(f"    Ambari (AMBARIUI/AMBARIWS): {ambari_host}")
        
        # RANGER - Ranger Admin host
        ranger_host = self.service_utils.get_component_host("RANGER", "RANGER_ADMIN")
        print(f"    Ranger (RANGER/RANGERUI): {ranger_host}")
        
        # HDFSUI - NameNode host
        namenode_host = self.service_utils.get_component_host("HDFS", "NAMENODE")
        print(f"    NameNode (HDFSUI): {namenode_host}")
        
        # SOLR - Solr server host (may not exist)
        solr_host = self.service_utils.get_component_host("SOLR", "SOLR_SERVER") or namenode_host
        print(f"    Solr (SOLR): {solr_host}")
        
        return {
            "rm_host": rm_host,
            "ambari_host": ambari_host,
            "ranger_host": ranger_host,
            "namenode_host": namenode_host,
            "solr_host": solr_host,
        }
    
    def is_hdfs_ha_enabled(self) -> bool:
        """Check if HDFS HA is enabled by looking for dfs.nameservices in hdfs-site."""
        try:
            nameservices = self.configs.get_property("hdfs-site", "dfs.nameservices")
            if nameservices and nameservices.strip():
                print(f"    HDFS HA enabled: nameservices = {nameservices}")
                return True
        except Exception as e:
            print(f"    Could not check HDFS HA status: {e}")
        return False
    
    def build_url(self, protocol: str, host: str, port: str, path: str = "") -> str:
        """Build a URL with the given components."""
        url = f"{protocol}://{host}:{port}"
        if path:
            url += path
        return url
    
    def render_topology(self, hostnames: dict) -> str:
        """
        Render the topology template by replacing URL placeholders.
        Keeps {{}} Ambari-managed variables as-is.
        """
        template_path = Path(__file__).parent.parent / "templates" / "knox-topology.j2"
        
        with open(template_path, "r") as f:
            content = f.read()
        
        # Default to http, can be changed to https if needed
        protocol = "http"
        ws_protocol = "ws"
        
        # =====================================================================
        # URL Replacements - Only for services with <hostname> placeholders
        # =====================================================================
        
        replacements = {
            # YARNUI - ResourceManager
            "YARNUI_URL": self.build_url(protocol, hostnames["rm_host"], "8088"),
            
            # AMBARI UI and WS
            "AMBARIUI_URL": self.build_url(protocol, hostnames["ambari_host"], str(AmbariConfig.PORT)),
            "AMBARIWS_URL": self.build_url(ws_protocol, hostnames["ambari_host"], str(AmbariConfig.PORT)),
            
            # RANGER
            "RANGER_URL": self.build_url(protocol, hostnames["ranger_host"], "6080"),
            "RANGERUI_URL": self.build_url(protocol, hostnames["ranger_host"], "6080"),
            
            # HDFS UI - NameNode
            "HDFSUI_URL": self.build_url(protocol, hostnames["namenode_host"], "50070"),
            
            # SOLR
            "SOLR_URL": self.build_url(protocol, hostnames["solr_host"], "8886", "/solr"),
        }
        
        print("\n  URL replacements:")
        for key, url in replacements.items():
            print(f"    {key}: {url}")
            content = content.replace(key, url)
        
        # =====================================================================
        # Add HaProvider if HDFS HA is enabled
        # =====================================================================
        print("\n  Checking HDFS HA status...")
        if self.is_hdfs_ha_enabled():
            print("    → Adding HaProvider for HDFS HA support")
            # Insert HaProvider before closing </gateway> tag
            content = content.replace(
                "</gateway>",
                self.HA_PROVIDER_XML + "            </gateway>"
            )
        else:
            print("    → HDFS HA not enabled, skipping HaProvider")
        
        return content
    
    def update_knox_topology(self, topology_content: str) -> None:
        """Update the Knox topology configuration in Ambari."""
        configs = get_ambari_configs()
        
        print("\n  Updating Knox topology configuration...")
        configs.set_property(
            "topology",
            "content",
            topology_content,
            version_note="[knox-enablement] Update topology with cluster hostnames"
        )


def run():
    """
    Update Knox topology configuration with cluster hostnames.
    
    This step:
    1. Gathers hostnames for services that have <hostname> placeholders
    2. Replaces URL placeholders with actual URLs
    3. Keeps {{}} Ambari-managed variables untouched
    4. Updates the Knox advanced topology config in Ambari
    
    Note: Knox restart is handled by the final restart_services step.
    
    Idempotent: Safe to run multiple times.
    """
    print("\n[Step 2] Updating Knox Topology Configuration")
    
    state = get_ambari_state()
    configs = get_ambari_configs()
    service_utils = ServiceUtils(configs, state)
    updater = TopologyUpdater(state, service_utils, configs)
    
    # Gather hostnames
    hostnames = updater.get_hostnames()
    
    # Render topology (replace URL placeholders, keep {{}} as-is)
    print("\n  Rendering topology...")
    topology_content = updater.render_topology(hostnames)
    
    # Preview - show a few replaced URLs
    print("\n  Preview (checking {{}} variables are preserved):")
    if "{{" in topology_content:
        print("    ✓ Ambari {{}} variables preserved")
    else:
        print("    ✗ Warning: No {{}} variables found")
    
    # Update Knox config
    updater.update_knox_topology(topology_content)
    
    print("\n[Step 2] Complete")
