#!/bin/bash
# -------------------------------------------------------------------
# Ambari Component Management Script
# This script gives you an option to DELETE or ADD the TIMELINE_READER
# component using the Ambari REST API.
#
# NOTE:
# - Ensure that the credentials provided have sufficient privileges.
# - Adjust sleep durations if needed.
# -------------------------------------------------------------------

# Set up environment variables
AMBARISERVER=$(hostname -f)
USER="admin"
PASSWORD="admin"
PORT=8080
PROTOCOL="http"
COMPONENT="TIMELINE_READER"

# Retrieve the cluster name from Ambari
CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" \
  -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | \
  sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

if [ -z "$CLUSTER" ]; then
    echo "Error: Unable to retrieve cluster name from Ambari."
    exit 1
fi

echo "Cluster identified: $CLUSTER"

# Prompt the user for the desired action
read -p "Do you want to DELETE or ADD the $COMPONENT component? (DELETE/ADD): " action

case "${action^^}" in
    DELETE)
        # -----------------------------------------------------------------
        # DELETE Operation:
        # 1. Identify the host running the TIMELINE_READER component.
        # 2. Stop the component (set state to INSTALLED).
        # 3. Delete the component from that host.
        # -----------------------------------------------------------------
        
        echo "Searching for host(s) running the $COMPONENT component..."
        hostname=$(curl -s -u "$USER:$PASSWORD" \
          -H "X-Requested-By: ambari" -X GET \
          "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=$COMPONENT" | \
          grep -o '"host_name" *: *"[^"]*' | sed 's/.*: *"//')

        if [ -z "$hostname" ]; then
            echo "Error: No host found with the $COMPONENT component."
            exit 1
        fi

        echo "$COMPONENT component found on host: $hostname"

        echo "Stopping $COMPONENT on $hostname..."
        curl -s -u "$USER:$PASSWORD" \
          -H "X-Requested-By: ambari" -X PUT \
          -d '{"RequestInfo":{"context":"Stop Timeline Service V2.0 Reader"},
               "Body":{"HostRoles":{"state":"INSTALLED"}}}' \
          "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/hosts/$hostname/host_components/$COMPONENT"
        echo "Waiting for the component to stop..."
        sleep 10

        echo "Deleting $COMPONENT from $hostname..."
        curl -s -u "$USER:$PASSWORD" \
          -H "X-Requested-By: ambari" -X DELETE \
          "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/hosts/$hostname/host_components/$COMPONENT"
        echo "$COMPONENT component has been deleted from host $hostname."
        ;;
        
    ADD)
        # -----------------------------------------------------------------
        # ADD Operation:
        # 1. Specify (or re-use) the host where the component should be added.
        # 2. Create the host component.
        # 3. Start the component (set state to STARTED).
        # -----------------------------------------------------------------
        
        # Prompt for host name to which the component will be added
        read -p "Enter the host name where you want to add the $COMPONENT component: " hostname
        if [ -z "$hostname" ]; then
            echo "Error: You must provide a host name."
            exit 1
        fi

        echo "Adding $COMPONENT component to host $hostname..."
        curl -s -u "$USER:$PASSWORD" \
          -H "X-Requested-By: ambari" -X POST \
          -d '{"HostRoles": {"component_name" : "'"$COMPONENT"'"}}' \
          "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/hosts/$hostname/host_components"
        echo "Waiting for the component addition to register..."
        sleep 10

        echo "Starting $COMPONENT on $hostname..."
        curl -s -u "$USER:$PASSWORD" \
          -H "X-Requested-By: ambari" -X PUT \
          -d '{"RequestInfo":{"context":"Start Timeline Service V2.0 Reader"},
               "Body":{"HostRoles":{"state":"STARTED"}}}' \
          "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/hosts/$hostname/host_components/$COMPONENT"
        echo "$COMPONENT component has been added and started on host $hostname."
        ;;
        
    *)
        echo "Invalid option selected. Please choose either DELETE or ADD."
        exit 1
        ;;
esac

echo "Operation completed."
