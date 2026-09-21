import os
from dotenv import load_dotenv

load_dotenv()


class SSHConfig:
    HOST = os.getenv("SSH_HOST", "localhost")
    PORT = int(os.getenv("SSH_PORT", 22))
    USERNAME = os.getenv("SSH_USERNAME", "root")
    PASSWORD = os.getenv("SSH_PASSWORD", "")
    KEY_PATH = os.getenv("SSH_KEY_PATH", "")


class AmbariConfig:
    HOST = os.getenv("AMBARI_HOST", "localhost")
    PORT = int(os.getenv("AMBARI_PORT", 8080))
    PROTOCOL = os.getenv("AMBARI_PROTOCOL", "http")
    USERNAME = os.getenv("AMBARI_USERNAME", "admin")
    PASSWORD = os.getenv("AMBARI_PASSWORD", "admin")


class RangerConfig:
    USERNAME = os.getenv("RANGER_USERNAME", "admin")
    PASSWORD = os.getenv("RANGER_PASSWORD", "Acceldata@01")
    PORT = int(os.getenv("RANGER_PORT", 6080))
