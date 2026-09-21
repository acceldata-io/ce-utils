"""
Step: Configure Knox proxy user settings in core-site.
Sets hadoop.proxyuser.knox.groups and hadoop.proxyuser.knox.hosts to "*"
"""

from steps.base import get_ambari_configs


def run():
    """
    Configure Knox proxy user settings in core-site.
    Sets hadoop.proxyuser.knox.groups and hadoop.proxyuser.knox.hosts to "*"
    
    Idempotent: Only updates if values are not already set to "*"
    """
    print("\n[Step 1] Configuring Knox proxy user in core-site")
    
    configs = get_ambari_configs()
    
    # Get current values
    current_groups = configs.get_property("core-site", "hadoop.proxyuser.knox.groups")
    current_hosts = configs.get_property("core-site", "hadoop.proxyuser.knox.hosts")
    
    print(f"  Current hadoop.proxyuser.knox.groups: {current_groups}")
    print(f"  Current hadoop.proxyuser.knox.hosts: {current_hosts}")
    
    # Check if update is needed
    updates_needed = {}
    
    if current_groups != "*":
        updates_needed["hadoop.proxyuser.knox.groups"] = "*"
    
    if current_hosts != "*":
        updates_needed["hadoop.proxyuser.knox.hosts"] = "*"
    
    if not updates_needed:
        print("  Already configured correctly. No changes needed.")
        print("[Step 1] Complete (no changes)")
        return
    
    # Apply only the needed updates
    print(f"  Updating {len(updates_needed)} property(ies)...")
    configs.set_properties(
        "core-site",
        updates_needed,
        version_note="Knox enablement: Set proxy user groups and hosts to *"
    )
    
    # Verify
    new_groups = configs.get_property("core-site", "hadoop.proxyuser.knox.groups")
    new_hosts = configs.get_property("core-site", "hadoop.proxyuser.knox.hosts")
    
    print(f"  Updated hadoop.proxyuser.knox.groups: {new_groups}")
    print(f"  Updated hadoop.proxyuser.knox.hosts: {new_hosts}")
    print("[Step 1] Complete")
