#!/bin/bash


if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <service1> <service2> ..."
    exit 1
fi

services=("$@")  # Use all command-line arguments as services

# Get the ODP stack version
stack_version=$(/usr/bin/odp-select --version)
host_name=$(hostname)
formatter=$(printf '=%.0s' {1..100})
echo "$formatter"
echo "Checking symlinks for host $host_name with current stack version $stack_version"
echo "$formatter"

for service in "${services[@]}"; do
    conf_path="/etc/$service/conf"

    if [ -d "/etc/$service/" ]; then
        if [ -L "$conf_path" ]; then
            target=$(readlink -f "$conf_path")
            current_dir=$(readlink "$conf_path")

            # Check if the conf_path exists
            if [ ! -d "$conf_path" ]; then
                echo "ERROR: conf path for service $service doesn't exist: $conf_path"
                continue
            fi

            expected_target="/etc/$service/$stack_version/0"
            pattern="/usr/odp/current/$service*/conf"

            # Use double brackets for extended conditional expressions
            if [[ "$current_dir" == $pattern ]]; then
                echo "OK: $service/conf symlink is correctly pointing to current dir $current_dir."
            else
                echo "ERROR: $service/conf symlink is pointing to current dir $current_dir, expected /usr/odp/current/$service*/conf."
            fi

            if [ "$target" == "$expected_target" ]; then
                echo "OK: Recursive check for $service/conf symlink is correctly configured to $target."
            else
                echo "ERROR: Recursive check for $service/conf symlink is pointing to $target, expected $expected_target."
            fi
        else
            echo "ERROR: $service/conf symlink not found in /etc/$service."
        fi
    else
        echo "WARN: $service service is not installed."
    fi
done