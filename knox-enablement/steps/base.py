"""
Base utilities for step functions.
"""

from modules import SSHClient, AmbariConfigs, get_ambari_state
from config.settings import SSHConfig, AmbariConfig


def get_ssh_client() -> SSHClient:
    """Get configured SSH client."""
    return SSHClient()


def get_ambari_configs() -> AmbariConfigs:
    """Get configured Ambari configs client."""
    state = get_ambari_state()
    return AmbariConfigs(
        host=AmbariConfig.HOST,
        user=AmbariConfig.USERNAME,
        password=AmbariConfig.PASSWORD,
        cluster=state.cluster_name,  # Auto-detected from API
        protocol=AmbariConfig.PROTOCOL,
        port=AmbariConfig.PORT,
        unsafe=True,
    )

