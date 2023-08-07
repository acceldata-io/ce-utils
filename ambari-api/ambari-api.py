import os
import requests
import json
from base64 import b64encode
import argparse
import ConfigParser

def get_ambari_credentials():
    """Get the Ambari credentials from the configuration file."""
    config = ConfigParser.ConfigParser()
    if not os.path.exists("ambari.cfg"):
            return "nil","nil","nil","nil","nil","nil"
    config.read("ambari.cfg")

    hostname = config.get("ambari", "hostname")
    port = config.get("ambari", "port")
    username = config.get("ambari", "username")
    password = config.get("ambari", "password")
    cluster_name = config.get("ambari", "cluster_name")
    httpss = config.get("ambari", "httpss")
    return hostname, port, username, password, cluster_name, httpss

def basic_auth(username, password):
    token = b64encode("{0}:{1}".format(username, password).encode('utf-8')).decode("ascii")
    return 'Basic {0}'.format(token)

hostname, port, username, password, cluster_name, httpss = get_ambari_credentials()

url = "{0}://{1}:{2}/api/v1/clusters/{3}/request_schedules".format(httpss, hostname, port, cluster_name)

headers = {
    "Authorization": basic_auth(username, password),
    "X-Requested-By": "ambari",
}

def stop_rolling_restart():
    response = requests.get(url, headers=headers)
    print "response:", response

    if response.status_code == 200:
        json_data = response.json()
        lst = json_data["items"]
        url_det = url + "/" + str(lst[-1]['RequestSchedule']['id'])
        response = requests.get(url_det, headers=headers)
        json_data = response.json()
        temp = json_data["RequestSchedule"]["batch"]["batch_requests"][0]['request_body']
        data = json.loads(temp)
        print ":::::::::::::::::::::  STOPPING THE BELOW SERVICE ROLLING RESTART AND SUBSEQUENT BATCHES :::::::::::::::::::: \n", data["Requests/resource_filters"][0]["component_name"]
        resp = requests.delete(url_det, headers=headers)
        if resp.status_code == 200:
            print "::::::::::::::::::::: STOPPED SUCCESSFULLY ::::::::::::::::::::"
    else:
        print response.content


def main():
    parser = argparse.ArgumentParser(description='Wrapper for script.py')
    parser.add_argument('function', choices=['stop-rolling-restart', 'func2', 'func3'], help='Specify the function to run')
    args = parser.parse_args()

    if hostname == "nil":
        print "ambari.cfg does not exist"
        return

    #check ambari-config
    if hostname == "ambari.server.hostname":
        print "edit ambari.cfg first with proper details"
        return

    # Call the appropriate function based on the input
    if args.function == 'stop-rolling-restart':
        stop_rolling_restart()

    # NOTE: if more functions are added use below statements and change accordingly in choices above

    # elif args.function == 'func2':
    #     func2()

    # elif args.function == 'func3':
    #     func3()

    else:
        print("Invalid function name.")


if __name__ == "__main__":
    main()