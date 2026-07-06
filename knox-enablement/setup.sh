#!/usr/bin/env bash
# Quick setup script for Knox Enablement
set -e

function usage() {
  printf "Usage: %s [-v] [-p <venv_path>] [-h]\n\n" "$0"
  printf "\t-v                Enable verbose output\n"
  printf "\t-p <venv_path>    Specify the path for the virtual environment (default: ./venv)\n"
  printf "\t-h                Show this help message"
}

VERBOSE=false
CURRENT_DIR="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"

while getopts ":vp::h" opt; do
  case ${opt} in
  v)
    VERBOSE=true
    ;;
  p)
    VENV_DIR="${OPTARG}"
    set -x
    ;;
  h)
    usage
    exit 0
    ;;
  \?)
    echo "Invalid option: -$OPTARG" >&2
    usage
    exit 1
    ;;
  esac
done

PARENT_DIR="$(dirname "$VENV_DIR")"

if [ ! -d "$PARENT_DIR" ]; then
  printf "Virtual environment parent directory '%s' does not exist. Creating it now...\n" "$PARENT_DIR"
  mkdir -p "$PARENT_DIR"
fi

shift $((OPTIND - 1))
pushd "$SCRIPT_DIR"

printf "=== Knox Enablement Setup ===\n"

# Create venv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
  printf "Creating virtual environment...\n"
  if ! python3.11 -m venv "$VENV_DIR"; then
    printf >&2 "Failed to create virtual environment. Ensure Python 3.11 is installed and available in your PATH.\n"
  fi
else
  printf "Virtual environment already exists, skipping creation\n"
fi

# Activate venv
if ! grep -q "^version" "$VENV_DIR/pyvenv.cfg"; then
  printf >&2 "The virtual environment at '%s' is not valid. Please delete it and try again.\n" "$VENV_DIR"
  exit 1
fi

printf "Activating virtual environment at '%s'...\n" "$VENV_DIR"
. "$VENV_DIR/bin/activate"

# Install dependencies
printf "Installing dependencies...\n"
if $VERBOSE; then
  pip install --upgrade pip
  #pip install -r requirements.txt
  pip install .
else
  pip install -q --upgrade pip
  #pip install -q -r requirements.txt
  pip install -q .
fi
printf "\n=== Setup Complete ===\n"
printf "Virtual environment has been created successfully. Run: . %s/bin/activate; knox-setup <STEP>\n\n" "$VENV_DIR"
popd
#printf "To return to '%s' run: popd\n" "$CURRENT_DIR"
