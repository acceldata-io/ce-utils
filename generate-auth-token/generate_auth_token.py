import base64
import configparser
import os


def generate_basic_auth_token(username, password):
    credentials = f"{username}:{password}"
    encoded_credentials = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
    basic_auth_token = f"{encoded_credentials}"
    return basic_auth_token


config = configparser.ConfigParser()
config_path = os.path.join(os.path.dirname(__file__), 'application.cfg')
config.read(config_path)

username = config.get("credentials", "username")
password = config.get("credentials", "password")

auth_token = generate_basic_auth_token(username, password)
print("Basic Auth Token:", auth_token)
