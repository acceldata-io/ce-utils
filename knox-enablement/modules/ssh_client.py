import paramiko
from typing import Tuple, Optional
from config.settings import SSHConfig


class SSHClient:
    """SSH client wrapper using paramiko for remote command execution."""

    def __init__(
        self,
        host: str = None,
        port: int = None,
        username: str = None,
        password: str = None,
        key_path: str = None,
    ):
        self.host = host or SSHConfig.HOST
        self.port = port or SSHConfig.PORT
        self.username = username or SSHConfig.USERNAME
        self.password = password or SSHConfig.PASSWORD
        self.key_path = key_path or SSHConfig.KEY_PATH
        self.client: Optional[paramiko.SSHClient] = None

    def connect(self) -> None:
        """Establish SSH connection."""
        self.client = paramiko.SSHClient()
        self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        connect_kwargs = {
            "hostname": self.host,
            "port": self.port,
            "username": self.username,
        }

        if self.key_path:
            connect_kwargs["key_filename"] = self.key_path
        elif self.password:
            connect_kwargs["password"] = self.password

        self.client.connect(**connect_kwargs)
        print(f"[SSH] Connected to {self.host}:{self.port}")

    def disconnect(self) -> None:
        """Close SSH connection."""
        if self.client:
            self.client.close()
            self.client = None
            print(f"[SSH] Disconnected from {self.host}")

    def execute(
        self, command: str, timeout: int = 300, raise_on_error: bool = True
    ) -> Tuple[int, str, str]:
        """
        Execute a command on the remote host.

        Args:
            command: Command to execute
            timeout: Command timeout in seconds
            raise_on_error: Raise exception if command fails

        Returns:
            Tuple of (exit_code, stdout, stderr)
        """
        if not self.client:
            self.connect()

        print(f"[SSH] Executing: {command}")
        stdin, stdout, stderr = self.client.exec_command(command, timeout=timeout)

        exit_code = stdout.channel.recv_exit_status()
        stdout_str = stdout.read().decode("utf-8").strip()
        stderr_str = stderr.read().decode("utf-8").strip()

        if exit_code != 0:
            print(f"[SSH] Command failed with exit code {exit_code}")
            if stderr_str:
                print(f"[SSH] stderr: {stderr_str}")
            if raise_on_error:
                raise RuntimeError(
                    f"Command failed with exit code {exit_code}: {stderr_str}"
                )
        else:
            print(f"[SSH] Command completed successfully")

        return exit_code, stdout_str, stderr_str

    def execute_sudo(
        self, command: str, timeout: int = 300, raise_on_error: bool = True
    ) -> Tuple[int, str, str]:
        """Execute command with sudo."""
        return self.execute(f"sudo {command}", timeout, raise_on_error)

    def upload_file(self, local_path: str, remote_path: str) -> None:
        """Upload a file to the remote host."""
        if not self.client:
            self.connect()

        sftp = self.client.open_sftp()
        try:
            print(f"[SSH] Uploading {local_path} -> {remote_path}")
            sftp.put(local_path, remote_path)
            print(f"[SSH] Upload complete")
        finally:
            sftp.close()

    def download_file(self, remote_path: str, local_path: str) -> None:
        """Download a file from the remote host."""
        if not self.client:
            self.connect()

        sftp = self.client.open_sftp()
        try:
            print(f"[SSH] Downloading {remote_path} -> {local_path}")
            sftp.get(remote_path, local_path)
            print(f"[SSH] Download complete")
        finally:
            sftp.close()

    def file_exists(self, remote_path: str) -> bool:
        """Check if a file exists on the remote host."""
        if not self.client:
            self.connect()

        sftp = self.client.open_sftp()
        try:
            sftp.stat(remote_path)
            return True
        except FileNotFoundError:
            return False
        finally:
            sftp.close()

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.disconnect()
        return False

