"""
Global state manager for Knox-specific data.
Stores values that are generated during the setup process.
"""

from typing import Optional


class KnoxState:
    """
    Singleton class to store Knox-specific state.
    Stores values like certificates that are generated during setup.
    """
    
    _instance: Optional['KnoxState'] = None
    _initialized: bool = False
    
    # Stored values
    _knox_cert_pem: Optional[str] = None
    _knox_cert_path: Optional[str] = None
    _knox_host: Optional[str] = None
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance
    
    def __init__(self):
        if KnoxState._initialized:
            return
        KnoxState._initialized = True
    
    @property
    def knox_cert_pem(self) -> Optional[str]:
        """Get the Knox gateway certificate PEM content."""
        return self._knox_cert_pem
    
    @knox_cert_pem.setter
    def knox_cert_pem(self, value: str):
        """Set the Knox gateway certificate PEM content."""
        self._knox_cert_pem = value
        print(f"[KnoxState] Stored Knox certificate PEM ({len(value)} bytes)")
    
    @property
    def knox_cert_path(self) -> Optional[str]:
        """Get the path where Knox cert was exported on the remote host."""
        return self._knox_cert_path
    
    @knox_cert_path.setter
    def knox_cert_path(self, value: str):
        """Set the Knox certificate path."""
        self._knox_cert_path = value
    
    @property
    def knox_host(self) -> Optional[str]:
        """Get the Knox host."""
        return self._knox_host
    
    @knox_host.setter
    def knox_host(self, value: str):
        """Set the Knox host."""
        self._knox_host = value
    
    def clear(self):
        """Clear all stored state."""
        self._knox_cert_pem = None
        self._knox_cert_path = None
        self._knox_host = None
        print("[KnoxState] State cleared")


# Global instance for easy access
_knox_state: Optional[KnoxState] = None


def get_knox_state() -> KnoxState:
    """Get the global KnoxState instance."""
    global _knox_state
    if _knox_state is None:
        _knox_state = KnoxState()
    return _knox_state

