#!/bin/bash
# =============================================================================
#  pulse_utility.sh — Acceldata Pulse Installation & Operations Utility
# =============================================================================
#
#  Synopsis:
#    ./pulse_utility.sh <command>
#
#  Purpose:
#    Automates OS/Docker prerequisites, Pulse installation, SSL/TLS setup,
#    log collection, and configuration backup for Acceldata Pulse.
#
#  Supported OS:
#    - RHEL 7, 8, 9
#    - Rocky Linux 8, 9
#    - AlmaLinux 8, 9
#    - CentOS 7
#    - Ubuntu 20.04+ / Debian
#
#  Required binaries:
#    bash, awk, sed, grep, tar, find, openssl, docker, jq, systemctl
#    (jq is auto-installed by configure_docker_daemon if missing)
#
#  Environment:
#    $AcceloHome  Pulse install directory (sourced from /etc/profile.d/ad.sh)
#
#  Exit codes:
#      0  success / help shown
#      1  generic failure (fatal error path)
#     86  user aborted, or AcceloHome could not be created
#     87  invalid user input
#     88  AcceloHome not empty / accelo binary missing
#     94  unsupported OS
#    100  invalid file path supplied by user
#    101  tarball extraction failed
#
#  Commands (see `./pulse_utility.sh` for the rich help screen):
#    preflight_os           preflight_docker
#    install_pulse          install_pulse_full
#    set_docker_data_root   fetch_krb_files            (optional)
#    configure_truststore   enable_ui_tls
#    collect_logs           backup_config
#
#  Author:    Acceldata Inc.
#  License:   Proprietary
# =============================================================================

# ---------------------------------------------------------------------------
#  ANSI color / glyph constants
# ---------------------------------------------------------------------------
YELLOW=$'\033[0;33m'
GREEN=$'\e[0;32m'
BLUE=$'\033[0;94m'
DARK_BLUE=$'\033[0;34m'
RED=$'\e[0;31m'
GREY=$'\033[90m'
ICyan=$'\033[0;96m'
CYAN=$'\033[0;36m'
NC=$'\e[0m'
TICK="✅"
CROSS="❌"

# ---------------------------------------------------------------------------
#  Usage / help screen
# ---------------------------------------------------------------------------

# Print the branded help screen: ASCII banner, environment status line, and
# a grouped grid of available commands. Always exits 0. Safe to call on any
# host (including macOS dev boxes) — does NOT invoke detect_os.
show_usage() {
  local script_name
  script_name=$(basename "$0")

  # Probe environment inside a subshell so we don't leak AcceloHome into the caller
  local AcceloHome_display os_display user_host
  AcceloHome_display=$(
    AcceloHome=""
    # shellcheck source=/dev/null
    [ -r /etc/profile.d/ad.sh ] && . /etc/profile.d/ad.sh 2>/dev/null
    echo "${AcceloHome:-(not set)}"
  )
  os_display=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
  os_display=${os_display:-$(uname -sr)}
  user_host="$(whoami)@$(hostname -s 2>/dev/null || hostname)"

  # Content width = 83 cols (matches figlet width 74 + 4 leading + 5 trailing)
  local rule_double="═══════════════════════════════════════════════════════════════════════════════════"

  # Banner
  printf '\n'
  printf '%s╔%s╗%s\n' "${CYAN}" "${rule_double}" "${NC}"
  printf '%s║%s                                                                                   %s║%s\n' "${CYAN}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s █████╗  ██████╗ ██████╗███████╗██╗     ██████╗  █████╗ ████████╗ █████╗%s      %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s██╔══██╗██╔════╝██╔════╝██╔════╝██║     ██╔══██╗██╔══██╗╚══██╔══╝██╔══██╗%s     %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s███████║██║     ██║     █████╗  ██║     ██║  ██║███████║   ██║   ███████║%s     %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s██╔══██║██║     ██║     ██╔══╝  ██║     ██║  ██║██╔══██║   ██║   ██╔══██║%s     %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s██║  ██║╚██████╗╚██████╗███████╗███████╗██████╔╝██║  ██║   ██║   ██║  ██║%s     %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║     %s╚═╝  ╚═╝ ╚═════╝ ╚═════╝╚══════╝╚══════╝╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝%s     %s║%s\n' "${CYAN}" "${DARK_BLUE}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║%s                                                                                   %s║%s\n' "${CYAN}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║%s                 %sP U L S E   ·   Installation & Operations Utility%s                 %s║%s\n' "${CYAN}" "${NC}" "${ICyan}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║%s                            %sAcceldata Inc.   |   v1.0%s                              %s║%s\n' "${CYAN}" "${NC}" "${GREY}" "${NC}" "${CYAN}" "${NC}"
  printf '%s║%s                                                                                   %s║%s\n' "${CYAN}" "${NC}" "${CYAN}" "${NC}"
  printf '%s╚%s╝%s\n' "${CYAN}" "${rule_double}" "${NC}"

  # Environment status line
  printf '  %s%s  ·  OS: %s  ·  AcceloHome: %s%s\n' "${GREY}" "${user_host}" "${os_display}" "${AcceloHome_display}" "${NC}"
  printf '\n'

  # Command grid — section printer (83-col content width to match banner)
  local grid_bottom="└───────────────────────────────────────────────────────────────────────────────"
  _section() {
    local title="$1"
    local header="┌─ ${title} "
    local pad_len=$(( 80 - ${#header} ))
    [ "$pad_len" -lt 0 ] && pad_len=0
    local dashes
    dashes=$(printf '─%.0s' $(seq 1 "$pad_len"))
    printf '  %s%s%s%s\n' "${CYAN}" "${header}" "${dashes}" "${NC}"
  }
  _endsection() {
    printf '  %s%s%s\n' "${CYAN}" "${grid_bottom}" "${NC}"
  }
  _row() {
    printf '  %s│%s  %s%-28s%s %s\n' "${CYAN}" "${NC}" "${BLUE}" "$1" "${NC}" "$2"
  }

  _section "SETUP"
  _row "preflight_os"     "Verify umask, SELinux, and sysctl settings"
  _row "preflight_docker" "Check/install Docker and daemon config"
  _endsection

  _section "INSTALL"
  _row "install_pulse"              "Install Acceldata Pulse (offline)"
  _row "install_pulse_full"         "OS + Docker prereqs + Pulse initial setup"
  _endsection

  _section "OPTIONAL"
  _row "set_docker_data_root"    "Relocate Docker data dir to a custom volume"
  _row "fetch_krb_files"         "Copy krb5.conf + HDFS keytab (kerberized clusters)"
  _endsection

  _section "SSL / TLS"
  _row "configure_truststore"    "Mount Java cacerts into Pulse containers"
  _row "enable_ui_tls"           "Enable native HTTPS on Pulse UI (ad-pulse-ui TLS)"
  _endsection

  _section "OPERATIONS"
  _row "collect_logs"        "Tar all Pulse container logs"
  _row "backup_config"        "Tar all Pulse configuration files"
  _endsection

  # Usage footer
  printf '\n'
  printf '  %sUsage:%s   ./%s %s<command>%s\n'  "${YELLOW}" "${NC}" "${script_name}" "${GREEN}" "${NC}"
  printf '  %sExample:%s ./%s %sinstall_pulse_full%s\n' "${YELLOW}" "${NC}" "${script_name}" "${GREEN}" "${NC}"
  printf '\n'

  unset -f _section _endsection _row
  exit 0
}


# ---------------------------------------------------------------------------
#  Logging helpers
#  All message helpers accept a single string argument and prefix it with
#  a colored status glyph. Errors go to stderr; info/success go to stdout.
# ---------------------------------------------------------------------------

# Print a green "Success" message. Use when an action was just performed.
print_success() {
  echo -e "${GREEN}${TICK} Success: $1${NC}"
}

# Print a blue "Success" message. Use for "already-configured" / no-op paths
# where the desired state was already present.
print_info() {
  echo -e "${BLUE}${TICK} Success: $1${NC}"
}

# Print a yellow "Warning" message. Non-fatal, user attention recommended.
print_warning() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

# Print a red "Error" message and exit 1. Use for unrecoverable failures.
print_error() {
  echo -e "${RED}${CROSS} Error: $1${NC}" >&2
  exit 1
}

# Print a red "Error" message but do NOT exit. Use when the caller wants to
# recover or print additional context before exiting.
print_error_soft() {
  echo -e "${RED}${CROSS} Error: $1${NC}" >&2
}

# Print a visually separated section header. Used to announce the start of
# a phase (e.g. "Checking Docker...").
print_header() {
  local separator="${GREY}***********************************************************************************${NC}"
  echo -e "${separator}"
  echo "$1"
  echo -e "${separator}"
}

# Check if a command-line argument is provided
[ -z "${1:-}" ] && { show_usage; }

# Run all OS-level preflight checks required before installing Pulse:
# system specs, umask, SELinux, sysctl.
#
# Exits:  94 if OS is unsupported (via detect_os)
preflight_os() {
  detect_os
  print_system_info | sed -e "s/\(.*\)/${YELLOW}\1${NC}/"
  check_umask
  check_selinux
  configure_sysctl
}

# Run all Docker preflight checks: install Docker if missing, then apply the
# Pulse-required daemon configuration.
#
# Exits:  1 on install/config failure, 94 if OS is unsupported
preflight_docker() {
  detect_os
  install_docker
  configure_docker_daemon
}

# Convenience wrapper: run full OS + Docker preflight, then install Pulse.
# Equivalent to: preflight_os && preflight_docker && install_pulse
install_pulse_full() {
  preflight_os
  preflight_docker
  install_pulse
}

# ---------------------------------------------------------------------------
#  OS detection
# ---------------------------------------------------------------------------
os=""
os_id=""
os_major_version=""

# Detect the host OS and populate the $os, $os_id, and $os_major_version
# globals. Called on demand (not at script-load) so show_usage() still works
# on unsupported platforms such as macOS dev boxes.
#
# Globals set:  os, os_id, os_major_version
# Exits:        94 if OS is unrecognized
detect_os() {
  if [ -n "$os" ]; then
    return 0
  fi
  if [ ! -r /etc/os-release ]; then
    echo -e "${RED}${CROSS} /etc/os-release not found; OS not supported${NC}"
    exit 94
  fi
  # Parse ID, ID_LIKE, and VERSION_ID from /etc/os-release
  os_id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
  local id_like
  id_like=$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print $2}' /etc/os-release)
  local version_id
  version_id=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2); print $2}' /etc/os-release)
  os_major_version=${version_id%%.*}

  case "$os_id" in
    ubuntu|debian)
      os="Ubuntu"
      ;;
    rhel)
      os="RHEL"
      ;;
    rocky)
      os="Rocky"
      ;;
    almalinux)
      os="AlmaLinux"
      ;;
    centos)
      os="CentOS"
      ;;
    *)
      # Fall back to ID_LIKE for less common derivatives
      case " $id_like " in
        *" rhel "*|*" centos "*|*" fedora "*)
          os="RHEL"
          ;;
        *" debian "*|*" ubuntu "*)
          os="Ubuntu"
          ;;
        *)
          echo -e "${RED}${CROSS} OS not supported (ID=$os_id)${NC}"
          exit 94
          ;;
      esac
      ;;
  esac
}

# Return 0 if the detected OS is in the RHEL family (RHEL, Rocky, AlmaLinux,
# CentOS); non-zero otherwise. Requires detect_os to have been called first.
is_rhel_family() {
  case "$os" in
    RHEL|Rocky|AlmaLinux|CentOS) return 0 ;;
    *) return 1 ;;
  esac
}

# Print a summary of the host: OS name/version, CPU cores, memory, storage.
# Output is piped through a color filter by preflight_os.
print_system_info() {
  detect_os
  # OS information
  os_version=$(awk -F'=' '/VERSION_ID/ {gsub(/"/, "", $2); print $2}' /etc/os-release)
  os_pretty=$(awk -F'=' '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2}' /etc/os-release)
  echo -e "${GREY}***********************************************************************************${NC}"
  echo -e "${ICyan}OS: ${os_pretty:-$os $os_version}${NC}"

  # Number of CPU cores
  cpu_cores=$(nproc)
  echo -e "${GREY}***********************************************************************************${NC}"
  echo -e "${ICyan}Number of CPU cores: $cpu_cores${NC}"

  # Memory information
  echo -e "${GREY}***********************************************************************************${NC}"
  echo -e "${ICyan}Memory Information:${NC}"
  free -h

  # Storage information (excluding Docker and tmpfs filesystems)
  echo -e "${GREY}***********************************************************************************${NC}"
  echo -e "${ICyan}Storage Information:${NC}"
  df -hP | grep -vE 'docker|tmpfs'

  # Additional system details can be added here
}


# ---------------------------------------------------------------------------
#  OS prerequisite checks
# ---------------------------------------------------------------------------

# Ensure the system umask is set to 022. Appends `umask 0022` to /etc/profile
# if not already present. Idempotent.
check_umask() {
  print_header "Checking Umask..."
  if grep -q 022 /etc/profile 2>/dev/null; then
      print_info "Umask is correctly set (022)."
  else
      echo "Umask not set. Setting umask to 0022."
      echo "umask 0022" >> /etc/profile 2>/dev/null
      print_success "Umask set to 0022."
  fi
}

# Set SELinux to permissive mode on RHEL-family hosts. No-op on Ubuntu/Debian
# or when SELinux is already disabled. Updates /etc/selinux/config so the
# change persists across reboots.
check_selinux() {
  print_header "Checking SELinux..."

  # SELinux is only relevant on the RHEL family
  if ! is_rhel_family; then
      print_info "SELinux check skipped (not a RHEL-family OS)."
      return 0
  fi

  # Prefer getenforce; fall back to sestatus if present; otherwise read /etc/selinux/config
  local current_mode=""
  if command -v getenforce &>/dev/null; then
      current_mode=$(getenforce 2>/dev/null)
  elif command -v sestatus &>/dev/null; then
      current_mode=$(sestatus 2>/dev/null | awk -F: '/Current mode/ {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
  elif [ -r /etc/selinux/config ]; then
      current_mode=$(awk -F= '/^SELINUX=/{print $2}' /etc/selinux/config)
  fi

  case "$current_mode" in
      Enforcing|enforcing)
          command -v setenforce &>/dev/null && setenforce 0 2>/dev/null
          if [ -f /etc/selinux/config ]; then
              sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null
          fi
          print_success "SELinux set to permissive."
          ;;
      *)
          print_info "SELinux is already disabled or not enforcing (mode: ${current_mode:-unknown})."
          ;;
  esac
}

# Ensure vm.max_map_count=262144 and net.ipv4.ip_forward=1 are set in
# /etc/sysctl.d/99-pulse.conf (takes precedence over defaults in
# /etc/sysctl.conf on RHEL/Rocky 9+) and applied to the running kernel.
# Idempotent: re-runs are safe and will not create duplicate entries.
#
# Exits:  1 if the drop-in file cannot be written or sysctl reload fails
configure_sysctl() {
  print_header "Checking Sysctl Settings for vm.max_map_count and Port Forwarding..."

  local sysctl_file="/etc/sysctl.d/99-pulse.conf"
  local changed=0

  # Ensure the drop-in directory and target file exist
  sudo mkdir -p /etc/sysctl.d || print_error "Cannot create /etc/sysctl.d"
  [ -f "$sysctl_file" ] || sudo touch "$sysctl_file" || print_error "Cannot create $sysctl_file"

  # Write each required key idempotently. Match ignores surrounding whitespace
  # so `vm.max_map_count = 262144` is treated the same as `vm.max_map_count=262144`.
  _ensure_sysctl_key() {
    local key="$1" value="$2"
    # Line-anchored regex that tolerates spaces around '='
    if sudo grep -Eq "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*${value}[[:space:]]*$" "$sysctl_file"; then
      return 0
    fi
    # Remove any stale entry for the same key (wrong value), then append fresh
    if sudo grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$sysctl_file"; then
      sudo sed -i -E "/^[[:space:]]*${key}[[:space:]]*=.*/d" "$sysctl_file" \
        || print_error "Failed to remove stale $key entry from $sysctl_file"
    fi
    echo "${key}=${value}" | sudo tee -a "$sysctl_file" >/dev/null \
      || print_error "Failed to append ${key}=${value} to $sysctl_file"
    changed=1
  }

  _ensure_sysctl_key "vm.max_map_count" "262144"
  _ensure_sysctl_key "net.ipv4.ip_forward" "1"

  if [ "$changed" -eq 1 ]; then
    echo "Applying new sysctl settings..."
    # Apply only our drop-in so unrelated broken entries in other sysctl.d
    # files don't surface noise here.
    if ! sudo sysctl -p "$sysctl_file" >/dev/null; then
      print_error "sysctl reload failed. Check $sysctl_file syntax and re-run."
    fi
  fi

  # Verify the running kernel actually has the expected values
  local live_mmc live_fwd
  live_mmc=$(sysctl -n vm.max_map_count 2>/dev/null)
  live_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
  if [ "$live_mmc" = "262144" ] && [ "$live_fwd" = "1" ]; then
    if [ "$changed" -eq 1 ]; then
      print_success "Sysctl settings configured and applied ($sysctl_file)."
    else
      print_info "Sysctl settings already present and active."
    fi
  else
    print_error "Sysctl reload reported success but kernel values are wrong (vm.max_map_count=$live_mmc, net.ipv4.ip_forward=$live_fwd). Check $sysctl_file."
  fi

  unset -f _ensure_sysctl_key
}

# ---------------------------------------------------------------------------
#  Docker installation & daemon config
# ---------------------------------------------------------------------------

# Install Docker CE if not already present, then verify the version is >= 20.10.
#
# Uses Docker's official per-distro yum/apt repository, installing only the
# core packages Pulse needs:
#   docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin
#
# We intentionally do NOT use get.docker.com — its bundled install list pulls
# in optional packages (docker-ce-rootless-extras, docker-model-plugin) that
# are not always available in every distro's Docker repo snapshot, and it runs
# with `--best` so one missing optional package fails the whole transaction.
#
# Repo URL per distro (Docker maintains separate per-distro repos):
#   Rocky:      download.docker.com/linux/rocky/docker-ce.repo
#   AlmaLinux:  download.docker.com/linux/alma/docker-ce.repo
#   RHEL:       download.docker.com/linux/rhel/docker-ce.repo
#   CentOS:     download.docker.com/linux/centos/docker-ce.repo
#   Fedora:     download.docker.com/linux/fedora/docker-ce.repo
#   Oracle:     download.docker.com/linux/oracle/docker-ce.repo
#   Ubuntu:     download.docker.com/linux/ubuntu (apt repo via keyring)
#   Debian:     download.docker.com/linux/debian (apt repo via keyring)
#
# Return 0 if the configured docker-ce-stable repo actually serves the
# docker-ce package for the current $releasever, non-zero otherwise. Used to
# detect the "repo loads but is empty" case on point-release hosts (e.g.
# Rocky 9.7 where $releasever=9.7 but Docker only publishes under .../9/).
#
# Args:   $1 — package manager (dnf or yum)
_docker_repo_has_docker_ce() {
  local pkg_mgr="$1"
  sudo "$pkg_mgr" --disablerepo='*' --enablerepo='docker-ce-stable' \
      list --available docker-ce >/dev/null 2>&1
}

# Requires: curl, sudo
# Exits:    1 if install fails, user declines, or version is too old
install_docker() {
  detect_os
  print_header "Checking Docker..."
  if ! command -v docker &> /dev/null; then
      echo -e "${RED}${CROSS} Docker is not installed.${NC}"

      local pkg_mgr="" pkg_mgr_plugins="" repo_url="" distro_slug=""
      if is_rhel_family; then
          if command -v dnf &>/dev/null; then
              pkg_mgr="dnf"
              pkg_mgr_plugins="dnf-plugins-core"
          else
              pkg_mgr="yum"
              pkg_mgr_plugins="yum-utils"
          fi
          # Pick the distro-matching repo. Docker hosts separate repos per distro.
          # Rocky uses the RHEL repo: Docker's rocky/ path can serve stale/empty
          # metadata on some hosts (seen on Rocky 9.7 — repomd.xml returns 200
          # but primary.xml is effectively empty), while rhel/ is reliably
          # populated and ABI-compatible.
          case "$os_id" in
              rocky)              distro_slug="rhel" ;;
              almalinux|alma)     distro_slug="alma" ;;
              rhel)               distro_slug="rhel" ;;
              centos)             distro_slug="centos" ;;
              fedora)             distro_slug="fedora" ;;
              ol|oracle|oraclelinux) distro_slug="oracle" ;;
              *)                  distro_slug="centos" ;;
          esac
          repo_url="https://download.docker.com/linux/${distro_slug}/docker-ce.repo"
      elif [ "$os" = "Ubuntu" ]; then
          pkg_mgr="apt-get"
      else
          print_error "Unsupported OS for automated Docker install: $os"
      fi

      echo
      echo -e "${CYAN}────${NC} ${ICyan}Docker install plan${NC} ${CYAN}──────────────────────────────────────────────${NC}"
      if is_rhel_family; then
          printf '  %s%s%s %sOS detected:%s %s%s %s%s\n' \
              "${YELLOW}" "●" "${NC}" "${BLUE}" "${NC}" "${ICyan}" "${os}" "${os_major_version:-?}" "${NC}"
          printf '  %s%s%s %sDocker repo:%s %s%s%s\n' \
              "${YELLOW}" "●" "${NC}" "${BLUE}" "${NC}" "${ICyan}" "${repo_url}" "${NC}"
          echo
          printf '  %s1.%s %sInstall repo plugins:%s\n'       "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo %s -y install %s%s\n'         "${GREY}" "${pkg_mgr}" "${pkg_mgr_plugins}" "${NC}"
          printf '  %s2.%s %sAdd Docker repo:%s\n'            "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo %s config-manager --add-repo %s%s\n' "${GREY}" "${pkg_mgr}" "${repo_url}" "${NC}"
          printf '  %s3.%s %sInstall Docker packages:%s\n'    "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo %s -y install docker-ce docker-ce-cli containerd.io \\%s\n' "${GREY}" "${pkg_mgr}" "${NC}"
          printf '       %s                   docker-buildx-plugin docker-compose-plugin%s\n' "${GREY}" "${NC}"
          printf '  %s4.%s %sEnable & start service:%s\n'     "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo systemctl enable --now docker%s\n' "${GREY}" "${NC}"
      else
          printf '  %s%s%s %sOS detected:%s %s%s%s\n' \
              "${YELLOW}" "●" "${NC}" "${BLUE}" "${NC}" "${ICyan}" "${os}" "${NC}"
          echo
          printf '  %s1.%s %sInstall apt prerequisites:%s\n'  "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg%s\n' "${GREY}" "${NC}"
          printf '  %s2.%s %sAdd Docker apt keyring and repo%s\n' "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '  %s3.%s %sInstall Docker packages:%s\n'    "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo apt-get install -y docker-ce docker-ce-cli containerd.io \\%s\n' "${GREY}" "${NC}"
          printf '       %s                        docker-buildx-plugin docker-compose-plugin%s\n' "${GREY}" "${NC}"
          printf '  %s4.%s %sEnable & start service:%s\n'     "${YELLOW}" "${NC}" "${BLUE}" "${NC}"
          printf '       %ssudo systemctl enable --now docker%s\n' "${GREY}" "${NC}"
      fi
      echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
      echo

      read -rp "$(echo -e "${YELLOW}▶ Proceed with Docker install?${NC} ${GREEN}[yes]${NC}/${RED}[no]${NC}: ")" choice
      case "$choice" in
          [Yy]|[Yy][Ee][Ss]) ;;
          *) print_error "Please install Docker manually and re-run the script." ;;
      esac

      if is_rhel_family; then
          # Remove conflicting podman-docker shim (it owns /usr/bin/docker on
          # Rocky/Alma/RHEL 8+). Non-fatal if not installed.
          if [ "${os_major_version:-0}" -ge 8 ] 2>/dev/null; then
              sudo rpm -q podman-docker &>/dev/null \
                  && sudo "$pkg_mgr" -y remove podman-docker
          fi

          sudo "$pkg_mgr" -y install "$pkg_mgr_plugins" \
              || print_error "Failed to install $pkg_mgr_plugins."

          # Clean any stale Docker repo files left from previous runs
          sudo rm -f /etc/yum.repos.d/docker-ce.repo /etc/yum.repos.d/docker-ce-staging.repo

          sudo "$pkg_mgr" config-manager --add-repo "$repo_url" \
              || print_error "Failed to add Docker repo from $repo_url."

          # Validate the repo actually serves docker-ce before calling install.
          # On hosts where $releasever expands to a point release (e.g. "9.7"
          # on Rocky 9.7) the repo metadata loads but is empty because Docker
          # only publishes under .../${distro}/9/. Pin $releasever to the
          # major version in the .repo file and retry.
          if ! _docker_repo_has_docker_ce "$pkg_mgr"; then
              if [ -n "${os_major_version:-}" ] && [ -f /etc/yum.repos.d/docker-ce.repo ]; then
                  print_warning "docker-ce not found at default \$releasever; pinning repo to ${os_major_version}."
                  sudo sed -i "s/\\\$releasever/${os_major_version}/g" /etc/yum.repos.d/docker-ce.repo
                  sudo "$pkg_mgr" clean metadata --disablerepo='*' --enablerepo='docker-ce-stable' >/dev/null 2>&1 || true
                  _docker_repo_has_docker_ce "$pkg_mgr" \
                      || print_error "Docker packages still not available after pinning \$releasever=${os_major_version}. Open '$repo_url' and confirm ${distro_slug}/${os_major_version}/ is published."
              else
                  print_error "Docker packages not available in '$repo_url'. Check network and re-run."
              fi
          fi

          # Install ONLY the packages Pulse needs. No --best, so dnf can pick
          # compatible versions if an exact match isn't available.
          sudo "$pkg_mgr" -y install \
              docker-ce docker-ce-cli containerd.io \
              docker-buildx-plugin docker-compose-plugin \
              || print_error "Docker package install failed. Check '$repo_url' availability and re-run."
      else
          require_command curl
          sudo apt-get update \
              || print_error "apt-get update failed."
          sudo apt-get install -y ca-certificates curl gnupg \
              || print_error "Failed to install apt prerequisites (ca-certificates, curl, gnupg)."
          sudo install -m 0755 -d /etc/apt/keyrings
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
              | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
              || print_error "Failed to import Docker apt keyring."
          sudo chmod a+r /etc/apt/keyrings/docker.gpg
          # shellcheck source=/dev/null
          echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
              | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
          sudo apt-get update \
              || print_error "apt-get update failed after adding Docker repo."
          sudo apt-get install -y \
              docker-ce docker-ce-cli containerd.io \
              docker-buildx-plugin docker-compose-plugin \
              || print_error "Docker package install failed."
      fi

      sudo systemctl enable --now docker \
          || print_error "Failed to enable/start docker.service."
  fi

  # Check the Docker version and ensure it's >= 20.10 (compare by major/minor integers)
  docker_version=$(docker -v 2>/dev/null | awk -F'[ ,]+' '{print $3}')
  docker_major=$(echo "$docker_version" | awk -F. '{print $1+0}')
  docker_minor=$(echo "$docker_version" | awk -F. '{print $2+0}')
  if [ "$docker_major" -gt 20 ] || { [ "$docker_major" -eq 20 ] && [ "$docker_minor" -ge 10 ]; }; then
      print_success "Docker Version $docker_version is Installed on $os ${os_major_version:-?}"
  else
      print_error "Docker is installed, but the version ($docker_version) is not compatible. Please install Docker version 20.10.x or above manually and re-run the script."
  fi
}


# Ensure jq is available on the host; install it via the local package
# manager if missing. Called before any daemon.json manipulation.
#
# Exits:  1 if jq can't be installed (no supported package manager, etc.)
_ensure_jq() {
  if command -v jq &>/dev/null; then
    return 0
  fi
  print_error_soft "jq not found; installing via package manager..."
  if command -v yum &>/dev/null; then
    sudo yum -y install jq >/dev/null \
      || print_error "Failed to install jq. Please install jq manually and re-run."
  elif command -v apt-get &>/dev/null; then
    if ! { sudo apt-get update -qq >/dev/null && sudo apt-get install -y jq >/dev/null; }; then
      print_error "Failed to install jq. Please install jq manually and re-run."
    fi
  else
    print_error "No supported package manager found to install jq."
  fi
}

# Best-effort install of 'pv' (pipe viewer) for extraction progress bars.
# On RHEL/Rocky/AlmaLinux 8/9 pv lives in EPEL, which may not be enabled.
# This function tries (in order): dnf/yum install pv, then enable EPEL and
# retry, then apt-get. Returns 0 if pv is available afterward, non-zero
# otherwise. Never exits — callers fall back to a non-pv rendering path.
_ensure_pv() {
  if command -v pv &>/dev/null; then
    return 0
  fi
  if command -v dnf &>/dev/null; then
    sudo dnf -y -q install pv &>/dev/null && return 0
    # pv is in EPEL for RHEL-family 8/9; try enabling EPEL once
    sudo dnf -y -q install epel-release &>/dev/null \
      && sudo dnf -y -q install pv &>/dev/null && return 0
  elif command -v yum &>/dev/null; then
    sudo yum -y -q install pv &>/dev/null && return 0
    sudo yum -y -q install epel-release &>/dev/null \
      && sudo yum -y -q install pv &>/dev/null && return 0
  elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y -qq pv &>/dev/null && return 0
  fi
  return 1
}

# Deep-merge a JSON fragment into /etc/docker/daemon.json. Existing keys are
# preserved; conflicting keys are overwritten by the fragment. Creates the
# file if missing, backs it up (timestamped) before modifying, and no-ops if
# the merged result is identical to the current file.
#
# Args:    $1 — JSON string to merge into daemon.json
# Returns: 0 if the file was changed OR already contained the requested state.
#          Prints "already configured" via print_info on no-op.
# Exits:   1 if the merge or write fails
_daemon_json_merge() {
  local fragment="$1"
  _ensure_jq
  mkdir -p /etc/docker

  if [ -f /etc/docker/daemon.json ]; then
    # Validate existing JSON; if malformed, back it up and start from {}
    if ! jq empty /etc/docker/daemon.json 2>/dev/null; then
      print_error_soft "/etc/docker/daemon.json is not valid JSON; backing up."
      cp /etc/docker/daemon.json "/etc/docker/daemon.json.bk.$(date +%s)"
      echo '{}' > /etc/docker/daemon.json
    fi

    local merged current_norm merged_norm
    merged=$(jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$fragment")) \
      || print_error "Failed to merge configuration into /etc/docker/daemon.json"

    current_norm=$(jq -S . /etc/docker/daemon.json)
    merged_norm=$(echo "$merged" | jq -S .)

    if [ "$current_norm" = "$merged_norm" ]; then
      return 1  # no change needed — caller decides what to print
    fi

    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bk.$(date +%s)"
    echo "$merged" > /etc/docker/daemon.json
  else
    echo "$fragment" > /etc/docker/daemon.json
  fi
  return 0
}

# Apply Pulse-required Docker daemon settings (live-restore, log rotation)
# to /etc/docker/daemon.json. Uses jq to deep-merge with any existing config
# so user customizations (registry mirrors, storage driver, etc.) are kept.
# Creates a timestamped backup before any modification. Restarts Docker.
#
# Requires: jq (auto-installed via yum/apt), systemctl
# Exits:    1 on merge failure, install failure, or Docker restart failure
configure_docker_daemon() {
  print_header "Configuring Docker Daemon Settings..."

  local required_config='{
    "live-restore": true,
    "log-driver": "json-file",
    "log-opts": {
      "mode": "non-blocking",
      "max-buffer-size": "4m",
      "max-size": "10m",
      "max-file": "3"
    }
  }'

  if ! _daemon_json_merge "$required_config"; then
    print_info "Docker daemon is already configured."
    return 0
  fi

  print_success "Docker daemon settings updated."
  systemctl daemon-reload
  systemctl enable docker >/dev/null
  if systemctl restart docker; then
    print_success "Docker daemon configured."
  else
    print_error "Failed to restart Docker after updating daemon.json"
  fi
}

# Relocate Docker's data-root (default /var/lib/docker) to a custom volume.
# Pulse container images consume ~15 GB; on hosts where /var is small this
# needs to move to a dedicated data volume. This command:
#   1. Detects the current data-root.
#   2. Prompts for the target directory (required).
#   3. Offers to migrate existing content via rsync (Docker stopped).
#   4. Merges `"data-root": "<target>"` into /etc/docker/daemon.json using
#      the same deep-merge helper as configure_docker_daemon, preserving
#      live-restore / log-opts / registry-mirrors / etc.
#   5. Restarts Docker and verifies the new root is active.
#
# Idempotent: if data-root is already set to the target, the function exits
# with a friendly message and no changes.
#
# Requires: docker, jq (auto-installed), rsync, systemctl
# Exits:    1 on migration/restart failure, 87 on invalid input / user abort
set_docker_data_root() {
  print_header "Relocating Docker data-root..."
  require_command docker

  # ---- Step 1: determine current data-root ----
  local current_root
  current_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
  current_root=${current_root:-/var/lib/docker}
  echo -e "  ${BLUE}● Current data-root:${NC} ${ICyan}${current_root}${NC}"

  # ---- Step 2: prompt for target ----
  echo
  echo -e "${GREY}Target must be on a volume with ample free space — Pulse pulls${NC}"
  echo -e "${GREY}roughly 15 GB of container images during install.${NC}"
  echo
  local target_root
  read -rep "$(echo -e "${YELLOW}▶ New Docker data directory${NC} ${GREY}(e.g. /grid1/docker)${NC}: ")" target_root
  if [ -z "$target_root" ]; then
    print_error "Target directory cannot be empty."
  fi
  # Normalize: strip any trailing slash
  target_root="${target_root%/}"

  # Idempotent no-op
  if [ "$target_root" = "$current_root" ]; then
    print_info "Docker data-root is already set to ${target_root}."
    return 0
  fi

  # ---- Step 3: validate / create target ----
  sudo mkdir -p "$target_root" || print_error "Cannot create target directory: $target_root"
  if [ ! -w "$target_root" ] && ! sudo test -w "$target_root"; then
    print_error "Target directory is not writable: $target_root"
  fi

  # ---- Step 4: decide on migration ----
  local migrate="no" current_nonempty=0
  if [ -d "$current_root" ] && sudo test -n "$(sudo ls -A "$current_root" 2>/dev/null | head -n1)"; then
    current_nonempty=1
  fi

  if [ "$current_nonempty" -eq 1 ]; then
    echo
    echo -e "${GREY}Existing Docker content was detected at ${current_root}.${NC}"
    echo -e "${GREY}Migrating preserves container images, volumes, and networks.${NC}"
    read -rp "$(echo -e "${YELLOW}▶ Migrate existing Docker content to new location?${NC} ${GREEN}[yes]${NC}/${RED}[no]${NC}: ")" ans
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) migrate="yes"; require_command rsync ;;
      *) migrate="no" ;;
    esac
  fi

  # ---- Step 5: preview plan ----
  echo
  echo -e "${CYAN}────${NC} ${ICyan}Action plan${NC} ${CYAN}──────────────────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}1.${NC} ${BLUE}Stop Docker:${NC}"
  echo -e "       ${GREY}sudo systemctl stop docker docker.socket${NC}"
  if [ "$migrate" = "yes" ]; then
    echo -e "  ${YELLOW}2.${NC} ${BLUE}Migrate:${NC}"
    echo -e "       ${GREY}sudo rsync -aHAX --numeric-ids ${current_root}/ ${target_root}/${NC}"
    echo -e "  ${YELLOW}3.${NC} ${BLUE}Update /etc/docker/daemon.json:${NC}"
    echo -e "       ${GREY}merge \"data-root\": \"${target_root}\"${NC}"
    echo -e "  ${YELLOW}4.${NC} ${BLUE}Start Docker:${NC}"
    echo -e "       ${GREY}sudo systemctl start docker${NC}"
    echo -e "  ${YELLOW}5.${NC} ${BLUE}Verify new data-root is active${NC}"
  else
    echo -e "  ${YELLOW}2.${NC} ${BLUE}Update /etc/docker/daemon.json:${NC}"
    echo -e "       ${GREY}merge \"data-root\": \"${target_root}\"${NC}"
    echo -e "  ${YELLOW}3.${NC} ${BLUE}Start Docker:${NC}"
    echo -e "       ${GREY}sudo systemctl start docker${NC}"
    echo -e "  ${YELLOW}4.${NC} ${BLUE}Verify new data-root is active${NC}"
  fi
  echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
  echo
  read -rp "$(echo -e "${YELLOW}▶ Proceed?${NC} ${GREEN}[yes]${NC}/${RED}[no]${NC}: ")" proceed
  case "$proceed" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *) echo -e "${CYAN}User declined. No changes made.${NC}"; exit 87 ;;
  esac

  # ---- Step 6: execute ----
  echo -e "${GREY}Stopping docker...${NC}"
  sudo systemctl stop docker docker.socket 2>/dev/null || true

  if [ "$migrate" = "yes" ]; then
    echo -e "${CYAN}Migrating ${ICyan}${current_root}${CYAN} → ${ICyan}${target_root}${CYAN}...${NC}"
    echo -e "${GREY}(this can take a while; progress shown below)${NC}"
    if ! sudo rsync -aHAX --numeric-ids --info=progress2 "${current_root}/" "${target_root}/"; then
      sudo systemctl start docker 2>/dev/null || true
      print_error "rsync migration failed. Docker restarted with original data-root."
    fi
    print_success "Migration complete."
  fi

  local fragment
  fragment=$(printf '{"data-root": "%s"}' "$target_root")
  if ! _daemon_json_merge "$fragment"; then
    # daemon.json already contained the target; still restart to pick it up
    print_info "daemon.json already had data-root=${target_root}; restarting Docker."
  else
    print_success "Updated /etc/docker/daemon.json with data-root=${target_root}."
  fi

  echo -e "${GREY}Starting docker...${NC}"
  sudo systemctl daemon-reload
  if ! sudo systemctl start docker; then
    print_error "Failed to start Docker after updating daemon.json. Check 'journalctl -u docker' and /etc/docker/daemon.json."
  fi

  # ---- Step 7: verify ----
  sleep 2
  local new_root
  new_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
  if [ "$new_root" = "$target_root" ]; then
    print_success "Docker data-root is now ${target_root}"
  else
    print_error "Docker restarted but reports data-root=${new_root:-<unknown>} (expected ${target_root}). Investigate /etc/docker/daemon.json."
  fi
}

# ---------------------------------------------------------------------------
#  Pulse installation
# ---------------------------------------------------------------------------

# Offline Pulse installer.
#
# Assumes the operator has already downloaded a Pulse tarball
# (pulse-<version>.tar.gz, containing cli_binaries/accelo.linux and ad-*.tgz
# Docker images) onto this node. The license file is NOT placed on disk —
# it is uploaded through the Pulse Web UI after first boot.
#
# Prompts, in order:
#   1. AcceloHome path       (default /data01/acceldata)
#   2. Tarball path          (full path to the local .tar.gz)
#   3. Extraction directory  (default: dirname of AcceloHome)
#   4. Load Docker images?   (yes/no; runs docker load for each ad-*.tgz)
#
# Then copies accelo.linux from the extracted tree into AcceloHome, runs
# `accelo init` twice (once to create /etc/profile.d/ad.sh, once after
# sourcing it — vendor-prescribed pattern).
#
# Exits:
#    86 — user aborted or AcceloHome could not be created
#    87 — invalid user input
#    88 — AcceloHome not empty
#   100 — tarball path invalid
#   101 — tarball extraction failed
install_pulse() {
    print_header "Installing Pulse (offline)..."

    # ---- Step 1: AcceloHome path ----
    local default_home="/data01/acceldata"
    echo -e "${GREY}AcceloHome is the Pulse data directory — all configs, data is stored under this path.${NC}"
    echo -e "${GREY}Pick a volume with ample free space (>= 200 GB).${NC}"
    echo
    read -rp "$(echo -e "${YELLOW}▶ AcceloHome data directory${NC} ${GREY}[default: ${default_home}]${NC}: ")" AcceloHome
    AcceloHome=${AcceloHome:-$default_home}
    if [ -z "$AcceloHome" ]; then
        print_error "AcceloHome path cannot be empty."
    fi
    echo -e "  ${BLUE}AcceloHome:${NC} ${ICyan}${AcceloHome}${NC}"

    if [ ! -d "$AcceloHome" ]; then
        read -rp "$(echo -e "${CYAN}Folder does not exist. Create ${ICyan}${AcceloHome}${CYAN}?${NC} ${GREEN}[yes]${NC}/${RED}[no]${NC}: ")" ANS
        case "$ANS" in
            [Yy]|[Yy][Ee][Ss])
                mkdir -p "$AcceloHome" || { echo -e "${RED}Failed to create $AcceloHome${NC}"; exit 86; }
                print_success "Created ${AcceloHome}"
                ;;
            *) echo -e "${CYAN}User declined folder creation. Exiting.${NC}"; exit 86 ;;
        esac
    fi

    # Guard: AcceloHome must be empty (apart from known-safe entries from earlier runs)
    local _found_extra=0 entry
    shopt -s nullglob dotglob
    for entry in "${AcceloHome}"/*; do
        case "$(basename -- "$entry")" in
            work|accelo|accelo.linux) ;;
            *) _found_extra=1; break ;;
        esac
    done
    shopt -u nullglob dotglob
    if [ "$_found_extra" -ne 0 ]; then
        print_error "AcceloHome (${AcceloHome}) is not empty. Clear it or choose a different path."
    fi

    # ---- Step 2: Tarball path ----
    echo
    echo -e "${GREY}The Pulse tarball (pulse-<version>.tar) must already be present on${NC}"
    echo -e "${GREY}this host. If you don't have it yet, either:${NC}"
    echo -e "${GREY}  • copy it over from another machine (scp / rsync), or${NC}"
    echo -e "${GREY}  • request a download link from Acceldata support.${NC}"
    echo
    read -rep "$(echo -e "${YELLOW}▶ Full path to Pulse tarball${NC} ${GREY}(e.g. /tmp/pulse-4.1.0.tar)${NC}: ")" pulpath
    if [ -z "$pulpath" ]; then
        print_error "Tarball path cannot be empty. Place the Pulse tarball on this host first, then re-run."
    fi
    if [ ! -f "$pulpath" ]; then
        print_error "Tarball not found at: ${pulpath}
   Copy it to this host (scp / rsync) or ask Acceldata support for a download link, then re-run."
    fi
    if [ ! -r "$pulpath" ]; then
        print_error "Tarball exists but is not readable: ${pulpath}
   Fix permissions (e.g. chmod +r) and re-run."
    fi
    echo -e "  ${BLUE}Tarball:${NC} ${ICyan}${pulpath}${NC}"

    # ---- Step 3: Extraction directory ----
    echo
    local default_extract
    default_extract=$(dirname -- "$AcceloHome")
    read -rep "$(echo -e "${YELLOW}▶ Where should the tarball be extracted?${NC} ${GREY}[default: ${default_extract}]${NC}: ")" extract_dir
    extract_dir=${extract_dir:-$default_extract}
    mkdir -p "$extract_dir" || print_error "Cannot create extraction directory: $extract_dir"
    if [ ! -w "$extract_dir" ]; then
        print_error "Extraction directory not writable: $extract_dir"
    fi
    echo -e "  ${BLUE}Will extract into:${NC} ${ICyan}${extract_dir}${NC}"

    # Tarball size (for pv progress bar or fallback polling)
    local tar_size tar_size_hr
    tar_size=$(stat -c %s "$pulpath" 2>/dev/null || stat -f %z "$pulpath" 2>/dev/null)
    tar_size_hr=$(du -h "$pulpath" 2>/dev/null | awk '{print $1}')

    # Free-space guard: the Pulse tarball is ~24 GB uncompressed and extracts
    # to ~24 GB on disk. Require that much free space + 10% headroom in
    # extract_dir before we start, otherwise tar fails partway through with
    # an opaque ENOSPC error.
    local free_bytes needed_bytes free_hr
    free_bytes=$(df -PB1 "$extract_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    needed_bytes=$(( tar_size + tar_size / 10 ))  # 110% of tarball size
    free_hr=$(df -Ph "$extract_dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_bytes" ] && [ -n "$tar_size" ] && [ "$free_bytes" -lt "$needed_bytes" ]; then
        local needed_hr
        needed_hr=$(awk -v b="$needed_bytes" 'BEGIN {printf "%.1fG", b/1024/1024/1024}')
        print_error "Not enough free space in ${extract_dir}: have ${free_hr:-?}, need ~${needed_hr} (tarball ${tar_size_hr} + 10% headroom). Pick a larger volume or free up space."
    fi
    echo -e "  ${BLUE}Free space in ${extract_dir}:${NC} ${ICyan}${free_hr:-?}${NC} ${GREY}(need ~${tar_size_hr:-?})${NC}"

    echo -e "${CYAN}Extracting ${ICyan}${pulpath}${CYAN} (${tar_size_hr:-?}) → ${ICyan}${extract_dir}${CYAN}...${NC}"

    # Best-effort install of pv for a live progress bar. Falls back silently
    # if the host has no internet / no EPEL / no package manager.
    if ! command -v pv &>/dev/null; then
        echo -e "${GREY}Installing 'pv' for extraction progress bar (best effort)...${NC}"
        _ensure_pv || true
    fi

    if command -v pv &>/dev/null && [ -n "$tar_size" ]; then
        # Live progress bar with ETA
        if ! pv -s "$tar_size" "$pulpath" | tar -xf - -C "$extract_dir"; then
            echo -e "${RED}Failed to extract tarball${NC}"
            exit 101
        fi
    else
        # Fallback: show a rolling per-file status line (no pv available and
        # couldn't install it — probably an air-gapped / no-EPEL host).
        echo -e "${GREY}(pv unavailable; showing per-file status)${NC}"
        if ! tar -xvf "$pulpath" -C "$extract_dir" 2>&1 \
                | awk -v cyan="${CYAN}" -v nc="${NC}" -v grey="${GREY}" '
                    { n++; printf "\r%s[%d] %s%.100s%s\033[K", grey, n, cyan, $0, nc; fflush() }
                    END { printf "\n" }
                  '; then
            echo -e "${RED}Failed to extract tarball${NC}"
            exit 101
        fi
    fi

    # Pulse tarballs are flat: ./ad-*.tgz + ./cli_binaries/ land directly in
    # the extract dir, so untar_dir == extract_dir.
    local untar_dir="$extract_dir"

    # Sanity-check: we should now see at least the accelo binary there.
    if [ ! -f "$untar_dir/cli_binaries/accelo.linux" ]; then
        print_error "Extraction completed but $untar_dir/cli_binaries/accelo.linux is missing. Is this a Pulse tarball?"
    fi

    print_success "Extraction complete."
    echo -e "  ${BLUE}Untar directory:${NC} ${ICyan}${untar_dir}${NC}"

    # ---- Step 4: Load Docker images ----
    echo
    read -rp "$(echo -e "${YELLOW}▶ Load Pulse Docker images now?${NC} ${GREEN}[yes]${NC}/${RED}[no]${NC}: ")" load_images
    case "$load_images" in
        [Yy]|[Yy][Ee][Ss])
            if ! command -v docker &>/dev/null; then
                print_error "docker command not found. Run preflight_docker first."
            fi
            local count=0 tgz
            shopt -s nullglob
            for tgz in "$untar_dir"/ad-*.tgz; do
                echo -e "${GREY}  → docker load < ${tgz}${NC}"
                docker load -i "$tgz" >/dev/null \
                    || print_error "docker load failed for: $tgz"
                count=$((count + 1))
            done
            shopt -u nullglob
            if [ "$count" -eq 0 ]; then
                print_error "No ad-*.tgz files found under ${untar_dir}."
            fi
            print_success "Loaded ${count} Pulse Docker image archive(s)."
            ;;
        *)
            print_warning "Skipping image load. You can run this later with: ls -1 ${untar_dir}/*.tgz | xargs --no-run-if-empty -L 1 docker load -i"
            ;;
    esac

    # ---- Step 5: Copy accelo binary from the extracted tree ----
    echo
    local accelo_src="$untar_dir/cli_binaries/accelo.linux"
    cp "$accelo_src" "$AcceloHome/accelo" \
        || print_error "Failed to copy accelo binary to $AcceloHome/accelo"
    chmod +x "$AcceloHome/accelo"
    print_success "accelo binary placed at ${AcceloHome}/accelo"

    # ---- Step 6: accelo init (vendor-prescribed double-init) ----
    echo
    echo -e "${CYAN}Running ${ICyan}accelo init${CYAN}...${NC}"
    if (
        cd "$AcceloHome" || exit 1
        ./accelo init
        sleep 2
        # shellcheck source=/dev/null
        [ -f /etc/profile.d/ad.sh ] && source /etc/profile.d/ad.sh
        ./accelo init
    ); then
        print_success "accelo init completed successfully."
    else
        print_error "accelo init failed."
    fi

    # shellcheck source=/dev/null
    [ -f /etc/profile.d/ad.sh ] && source /etc/profile.d/ad.sh
    accelo info || true

    echo
    echo -e "${GREEN}${TICK} Pulse offline install prepared.${NC}"
    echo
    echo -e "${YELLOW}⚠ IMPORTANT — source the Accelo env into your current shell:${NC}"
    echo -e "      ${GREEN}source /etc/profile.d/ad.sh${NC}"
    echo -e "${GREY}  (install_pulse sourced it for its own subshell, but your${NC}"
    echo -e "${GREY}   outer shell still needs this before 'accelo' commands work.)${NC}"
    echo
    echo -e "${GREY}Next steps:${NC}"
    echo -e "  ${BLUE}1.${NC} Source env (above):      ${GREY}source /etc/profile.d/ad.sh${NC}"
    echo -e "  ${BLUE}2.${NC} Configure cluster:        ${GREY}accelo config cluster${NC}"
    echo -e "  ${BLUE}3.${NC} If cluster is kerberized: ${GREY}./$(basename "$0") fetch_krb_files${NC}"
    echo -e "  ${BLUE}4.${NC} Upload your license from the Pulse Web UI once it comes up."
}

# ---------------------------------------------------------------------------
#  Truststore / TLS configuration
# ---------------------------------------------------------------------------

# Wire a Java truststore (cacerts) into the Pulse core + connector containers.
# Use when the Hadoop cluster Pulse connects to uses SSL. Copies the cacerts
# file into $AcceloHome/config/security/ and adds volume mounts to:
#   - ad-core.yml           (ad-streaming service)
#   - ad-core-connectors.yml (ad-connectors, ad-sparkstats)
#   - ad-fsanalyticsv2-connector.yml
#
# Prompts:  yes/no "Is this a Pulse Core Server?"; path to cacerts file
# Globals:  AcceloHome (sourced from /etc/profile.d/ad.sh)
# Exits:    1 if AcceloHome unset, cacerts missing, or makeconfig fails
function configure_truststore {
# Ask if this is a Pulse Core Server
echo -e "${CYAN}Is this a Pulse Core Server? (yes/no):${NC}\c"
read -r is_pulse_core
case "$is_pulse_core" in
[Yy][Ee][Ss] | [Yy])
  is_pulse_core="yes"
  ;;
[Nn][Oo] | [Nn])
  is_pulse_core="no"
  ;;
*)
  echo "Invalid input. Please enter 'yes' or 'no'."
  exit 1
  ;;
esac

  if [[ "$is_pulse_core" != "yes" ]]; then
    echo -e "${YELLOW}Skipping SSL configuration: this is not a Pulse Core Server.${NC}"
    return 0
  fi

  if true; then
  # Load the ad.sh profile
  # shellcheck source=/dev/null
  source /etc/profile.d/ad.sh
  # Check if the AcceloHome variable is set
  if [[ -z "$AcceloHome" ]]; then
    echo -e "${RED}Error: AcceloHome variable is not set. Please set it before running the script.${NC}"
    exit 1
  fi

  # Ask for the path to the cacerts file
  read -rep "Enter the complete path of the cacerts file: " cacerts_path

  # Check if the cacerts file is present
  if [ ! -f "$cacerts_path" ]; then
    echo "Error: The cacerts file does not exist at $cacerts_path. Please ensure that the cacerts file is present before running the script."
    exit 1
  fi

  # Copy the cacerts file to $AcceloHome/config/security/
  cp "$cacerts_path" "$AcceloHome/config/security/"
  cp "$cacerts_path" "$AcceloHome/config/security/jssecacerts"

  # Update permissions on all files in $AcceloHome/config/security/
  chmod 0644 "$AcceloHome/config/security/"*

  # Check for the ad-core-connectors.yml file
  if [ ! -f "$AcceloHome/config/docker/addons/ad-core-connectors.yml" ]; then
    accelo admin makeconfig ad-core-connectors || {
      echo "Error: Failed to create ad-core-connectors.yml"
      exit 1
    }
  fi

  # Check for the ad-core.yml file
  if [ ! -f "$AcceloHome/config/docker/ad-core.yml" ]; then
    accelo admin makeconfig ad-core || {
      echo "Error: Failed to create ad-core.yml"
      exit 1
    }
  fi

  # Check for the ad-fsanalyticsv2-connector.yml file
  if [ ! -f "$AcceloHome/config/docker/addons/ad-fsanalyticsv2-connector.yml" ]; then
    accelo admin makeconfig ad-fsanalyticsv2-connector || {
      echo "Error: Failed to create ad-fsanalyticsv2-connector.yml"
      exit 1
    }
  fi

  if [ ! -f "$AcceloHome/config/security/cacerts" ]; then
    echo -e "${RED}Error: The cacerts file does not exist at $AcceloHome/config/security/cacerts. Please ensure that the cacerts file is present before running the script.${NC}"
    exit 1
  fi

  # Check the current volumes section in ad-core.yml
  volumes_section=$(awk '/ad-streaming:/,/ulimits:/' "$AcceloHome/config/docker/ad-core.yml")

  # Check if the cacerts file is already in the volumes section
  if echo "$volumes_section" | grep -q "$AcceloHome/config/security/cacerts"; then
    echo -e "${GREEN}The cacerts file is already in the volumes section of ad-core.yml${NC}"
  else
    # Add the cacerts file to the volumes section
    sed -i "/ad-streaming:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/cacerts:/usr/local/openjdk-8/lib/security/cacerts|" "$AcceloHome/config/docker/ad-core.yml"
    sed -i "/ad-streaming:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/jssecacerts:/usr/local/openjdk-8/lib/security/jssecacerts|" "$AcceloHome/config/docker/ad-core.yml"
    echo -e "${GREEN} Successfully added the cacerts file to the volumes section of ad-core.yml${NC}"
  fi

  # Check the current volumes section in ad-core-connectors.yml
  ad_core_volumes_section=$(awk '/ad-connectors:/,/ulimits:/' "$AcceloHome/config/docker/addons/ad-core-connectors.yml")

  # Check if the cacerts file is already in the volumes section
  if echo "$ad_core_volumes_section" | grep -q "$AcceloHome/config/security/cacerts"; then
    echo -e "${GREEN}The cacerts file is already in the volumes section of ad-core-connectors.yml${NC}"
  else
    # Add the cacerts file to the volumes section
    sed -i "/ad-connectors:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/cacerts:/usr/local/openjdk-8/lib/security/cacerts|" "$AcceloHome/config/docker/addons/ad-core-connectors.yml"
    sed -i "/ad-connectors:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/jssecacerts:/usr/local/openjdk-8/lib/security/jssecacerts|" "$AcceloHome/config/docker/addons/ad-core-connectors.yml"
    echo -e "${GREEN}Successfully added the cacerts file to the volumes section of ad-core-connectors.yml${NC}"
  fi

  ad_sparkstats_volumes_section=$(awk '/ad-sparkstats:/,/ulimits:/' "$AcceloHome/config/docker/addons/ad-core-connectors.yml")

  # Check if the cacerts file is already in the volumes section
  if echo "$ad_sparkstats_volumes_section" | grep -q "$AcceloHome/config/security/cacerts"; then
    echo -e "${GREEN}The cacerts file is already in the volumes section of ad-core-connectors.yml${NC}"
  else
    # Add the cacerts file to the volumes section
    sed -i "/ad-sparkstats:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/cacerts:/usr/local/openjdk-8/lib/security/cacerts|" "$AcceloHome/config/docker/addons/ad-core-connectors.yml"
    sed -i "/ad-sparkstats:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/jssecacerts:/usr/local/openjdk-8/lib/security/jssecacerts|" "$AcceloHome/config/docker/addons/ad-core-connectors.yml"
    echo -e "${GREEN}Successfully added the cacerts file to the volumes section of ad-core-connectors.yml${NC}"
  fi

  ad_fs_volumes_section=$(awk '/ad-fsanalyticsv2-connector:/,/ulimits:/' "$AcceloHome/config/docker/addons/ad-fsanalyticsv2-connector.yml")

  # Check if the cacerts file is already in the volumes section
  if echo "$ad_fs_volumes_section" | grep -q "$AcceloHome/config/security/cacerts"; then
    echo -e "${GREEN}The cacerts file is already in the volumes section of ad-core-connectors.yml${NC}"
  else
    # Add the cacerts file to the volumes section
    sed -i "/ad-fsanalyticsv2-connector:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/cacerts:/usr/local/openjdk-8/lib/security/cacerts|" "$AcceloHome/config/docker/addons/ad-fsanalyticsv2-connector.yml"
    sed -i "/ad-fsanalyticsv2-connector:/,/ulimits:/ s|volumes:|volumes:\n    - $AcceloHome/config/security/jssecacerts:/usr/local/openjdk-8/lib/security/jssecacerts|" "$AcceloHome/config/docker/addons/ad-fsanalyticsv2-connector.yml"

    echo -e "${GREEN}Successfully added the cacerts file to the volumes section of ad-fsanalyticsv2-connector.yml${NC}"
  fi

  fi

}

# ---------------------------------------------------------------------------
#  UI TLS setup helpers
# ---------------------------------------------------------------------------

# Exit 1 if the named command is not on $PATH. Use for hard dependency checks.
#
# Args:   $1 — command name to look for (e.g. "openssl")
# Exits:  1 if not found
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || print_error "$cmd not found. Please install it."
}

# Prompt for a passphrase without echoing it to the terminal.
# The passphrase is stored in the caller-visible variable $passphrase.
#
# Args:   $1 — prompt string (colon appended automatically)
# Sets:   $passphrase
read_passphrase() {
  local prompt="$1"
  prompt+=": "
  read -rs -p "$prompt" passphrase
  echo  # Print a newline for a cleaner output
}

# Copy a file to a destination, printing success or exiting on failure.
#
# Args:   $1 — source path, $2 — destination path
# Exits:  1 on copy failure
copy_file() {
  local source_file="$1"
  local destination="$2"

  if cp -f "$source_file" "$destination"; then
    print_success "File $source_file copied to $destination"
  else
    print_error "Failed to copy $source_file to $destination"
  fi
}

# Decrypt an encrypted PEM private key in place by stripping its passphrase.
# Writes to a temp file first to avoid destroying the key if openssl fails.
# Prompts the user for the passphrase. Sets file mode to 0600 after success.
#
# Globals:  cert_key (path to the private key)
# Exits:    1 on openssl failure (passphrase wrong, malformed key, etc.)
decrypt_private_key() {
  read_passphrase $'\e[36mEnter the passphrase to remove encryption from the private key\e[0m'
  local tmp_key
  tmp_key=$(mktemp) || print_error "Failed to create temp file for key conversion"
  if openssl rsa -in "$cert_key" -out "$tmp_key" -passin pass:"$passphrase" 2>/tmp/.openssl_err; then
    mv "$tmp_key" "$cert_key"
    chmod 0600 "$cert_key"
    rm -f /tmp/.openssl_err
    print_success "Password removed from private key"
  else
    rm -f "$tmp_key"
    print_error_soft "Failed to remove password from private key:"
    cat /tmp/.openssl_err >&2
    rm -f /tmp/.openssl_err
    exit 1
  fi
}

# Copy a certificate file into the Pulse proxy certs directory.
# Errors out if the source file does not exist.
#
# Args:     $1 — source path to a certificate or private-key file
# Globals:  AcceloHome
# Exits:    1 if the file does not exist
import_certificate() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    print_error "Certificate file not found: $file_path"
  fi
  copy_file "$file_path" "$AcceloHome/config/proxy/certs/$(basename "$file_path")"
}

# Enable native HTTPS on the Pulse web UI by terminating TLS inside the
# ad-pulse-ui container (no ad-proxy sidecar).
#
# Workflow:
#   1. Validate cert/key paths and passphrase.
#   2. Install cert/key as ssl.crt / ssl.key in $AcceloHome/config/proxy/certs.
#   3. Flip SSL_* env vars in the ad-pulse-ui section of ad-core.yml and add
#      the ./config/proxy/certs:/etc/acceldata/ssl volume mount.
#   4. Restart ad-pulse-ui and verify TLS on port 4000.
#
# Prompts:  paths to cert.crt and cert.key; passphrase (Enter for none)
# Globals:  AcceloHome
# Exits:    1 if any required command/file is missing or step fails
enable_ui_tls() {
  local PULSE_SERVICE="ad-pulse-ui"
  local PULSE_PORT=4000

  print_header "[1/9] Preflight: checking required tools and docker daemon"
  local required_commands=("openssl" "awk" "sed" "docker" "accelo")
  local cmd
  for cmd in "${required_commands[@]}"; do
    require_command "$cmd"
  done
  print_success "Found: ${required_commands[*]}"

  if ! docker info >/dev/null 2>&1; then
    print_error "Docker daemon is not reachable. Start docker and retry."
  fi
  print_success "Docker daemon is reachable"
  echo

  print_header "[2/9] Loading Acceldata environment"
  if [ -f "/etc/profile.d/ad.sh" ]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/ad.sh || print_error "Failed to source /etc/profile.d/ad.sh."
  else
    print_error "Environment file /etc/profile.d/ad.sh not found."
  fi
  if [ -z "${AcceloHome:-}" ] || [ ! -d "$AcceloHome" ]; then
    print_error "AcceloHome is not set or directory missing: '${AcceloHome:-<unset>}'"
  fi
  local AD_CORE_YML="$AcceloHome/config/docker/ad-core.yml"
  local CERT_DIR="$AcceloHome/config/proxy/certs"
  local host
  host="$(hostname -f 2>/dev/null || hostname)"
  print_success "AcceloHome = $AcceloHome"
  echo -e "${BLUE}→ Expected ad-core.yml path: ${NC}$AD_CORE_YML"
  if [ -f "$AD_CORE_YML" ]; then
    echo -e "${BLUE}  (exists — will be edited in place)${NC}"
  else
    echo -e "${YELLOW}  (missing — will be generated via 'accelo admin makeconfig ad-core' in step 5)${NC}"
  fi
  echo -e "${BLUE}→ Certs directory: ${NC}$CERT_DIR"
  if [ -d "$CERT_DIR" ]; then
    echo -e "${BLUE}  (exists)${NC}"
  else
    echo -e "${YELLOW}  (missing — will be created in step 6)${NC}"
  fi
  echo

  print_header "[3/9] Collecting certificate and key paths"
  local cert_crt cert_key
  read -rp $'\e[36mEnter the path to the server certificate file (cert.crt): \e[0m' cert_crt
  read -rp $'\e[36mEnter the path to the private key file (cert.key): \e[0m' cert_key
  echo

  echo -e "${BLUE}→ Checking that both files exist and are readable...${NC}"
  [ -f "$cert_crt" ] || print_error "Certificate file not found: $cert_crt"
  [ -f "$cert_key" ] || print_error "Private key file not found: $cert_key"
  [ -r "$cert_crt" ] || print_error "Certificate file not readable: $cert_crt"
  [ -r "$cert_key" ] || print_error "Private key file not readable: $cert_key"
  print_success "Cert and key files exist and are readable"
  echo

  print_header "[4/9] Validating certificate and private key"
  echo -e "${BLUE}→ Verifying certificate is PEM-encoded...${NC}"
  if openssl x509 -in "$cert_crt" -noout &>/dev/null; then
    print_success "Certificate is in PEM format"
  else
    print_error "Certificate is not in PEM format: $cert_crt"
  fi

  echo -e "${BLUE}→ Checking certificate expiry (must be valid for >0 days)...${NC}"
  if openssl x509 -in "$cert_crt" -noout -checkend 0 &>/dev/null; then
    local not_after
    not_after=$(openssl x509 -in "$cert_crt" -noout -enddate | cut -d= -f2)
    print_success "Certificate is not expired (notAfter: $not_after)"
  else
    print_error "Certificate has already expired: $cert_crt"
  fi

  echo -e "${BLUE}→ Detecting whether the private key is password-protected...${NC}"
  local key_encrypted="no"
  local key_pass=""
  if grep -qE 'BEGIN ENCRYPTED PRIVATE KEY|Proc-Type: 4,ENCRYPTED' "$cert_key"; then
    key_encrypted="yes"
    print_warning "Private key is encrypted — a passphrase will be required"
  else
    print_success "Private key is NOT encrypted — no passphrase needed"
  fi

  if [ "$key_encrypted" = "yes" ]; then
    read -rsp $'\e[36mEnter the private key passphrase (input is hidden): \e[0m' key_pass
    echo
    echo
    if [ -z "$key_pass" ]; then
      print_error "Private key is encrypted but no passphrase was provided."
    fi
    echo -e "${BLUE}→ Verifying passphrase unlocks the private key...${NC}"
    if openssl rsa -in "$cert_key" -passin pass:"$key_pass" -noout &>/dev/null; then
      print_success "Passphrase verified against private key"
    else
      print_error "Provided passphrase does not unlock the private key."
    fi
  fi

  echo -e "${BLUE}→ Confirming certificate and key belong to the same pair...${NC}"
  local crt_mod key_mod openssl_rsa_args=()
  [ -n "$key_pass" ] && openssl_rsa_args=(-passin "pass:$key_pass")
  crt_mod=$(openssl x509 -in "$cert_crt" -noout -modulus 2>/dev/null | openssl md5)
  key_mod=$(openssl rsa  -in "$cert_key" "${openssl_rsa_args[@]}" -noout -modulus 2>/dev/null | openssl md5)
  if [ -n "$crt_mod" ] && [ "$crt_mod" = "$key_mod" ]; then
    print_success "Certificate and key modulus match"
  else
    print_error "Certificate and private key do not match (modulus mismatch)."
  fi

  echo -e "${BLUE}→ Certificate details:${NC}"
  openssl x509 -in "$cert_crt" -noout -subject -issuer \
    || print_error "Failed to read certificate subject/issuer."
  echo

  print_header "[5/9] Ensuring ad-core.yml is present and inspecting current SSL state"
  if [ ! -f "$AD_CORE_YML" ]; then
    echo -e "${BLUE}→ ad-core.yml missing; generating via 'accelo admin makeconfig ad-core'...${NC}"
    accelo admin makeconfig ad-core || print_error "Failed to create ad-core.yml."
    print_success "Generated $AD_CORE_YML"
  else
    print_success "ad-core.yml already present"
  fi

  if ! grep -qE '^[[:space:]]{2}'"$PULSE_SERVICE"':[[:space:]]*$' "$AD_CORE_YML"; then
    print_error "Section '$PULSE_SERVICE:' not found in $AD_CORE_YML — cannot continue."
  fi
  print_success "Found '$PULSE_SERVICE:' section in ad-core.yml"

  local ssl_already_on
  ssl_already_on=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && ($0 ~ /SSL_ENFORCED=true/ || $0 ~ /SSL_ENABLED=true/) { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$ssl_already_on" -gt 0 ]; then
    print_warning "Pulse SSL appears to be already enabled in '$PULSE_SERVICE' section."
    local answer
    read -rp $'\e[31mContinue with SSL enablement anyway? [y/N]: \e[0m' answer
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) print_info "Continuing per user confirmation" ;;
      [Nn]|[Nn][Oo]|"")  echo "Exiting without changes."; return 0 ;;
      *)                 print_error "Invalid input. Aborting." ;;
    esac
  else
    print_success "SSL not yet enabled in '$PULSE_SERVICE' — safe to proceed"
  fi

  echo -e "${BLUE}→ Backing up ad-core.yml to ad-core.yml.bak...${NC}"
  cp "$AD_CORE_YML" "$AD_CORE_YML.bak" || print_error "Failed to back up ad-core.yml."
  print_success "Backup saved to $AD_CORE_YML.bak"
  echo

  print_header "[6/9] Installing certificate and key as ssl.crt / ssl.key"
  mkdir -p "$CERT_DIR" || print_error "Failed to create $CERT_DIR."

  echo -e "${BLUE}→ Copying cert and key into $CERT_DIR...${NC}"
  import_certificate "$cert_crt"
  import_certificate "$cert_key"

  local staged_crt staged_key
  staged_crt="$CERT_DIR/$(basename "$cert_crt")"
  staged_key="$CERT_DIR/$(basename "$cert_key")"
  echo -e "${BLUE}→ Renaming to canonical ssl.crt / ssl.key (the names ad-pulse-ui reads)...${NC}"
  if [ "$staged_crt" != "$CERT_DIR/ssl.crt" ]; then
    mv -f "$staged_crt" "$CERT_DIR/ssl.crt" || print_error "Failed to rename cert to ssl.crt."
  fi
  if [ "$staged_key" != "$CERT_DIR/ssl.key" ]; then
    mv -f "$staged_key" "$CERT_DIR/ssl.key" || print_error "Failed to rename key to ssl.key."
  fi
  chmod 0644 "$CERT_DIR/ssl.crt" || print_error "Failed to chmod ssl.crt."
  chmod 0600 "$CERT_DIR/ssl.key" || print_error "Failed to chmod ssl.key."
  print_success "Installed ssl.crt (0644) and ssl.key (0600) in $CERT_DIR"
  echo

  print_header "[7/9] Updating SSL_* env vars and volume mount in ad-pulse-ui"

  # Decide what value (and encrypted flag) to write for SSL_PASSPHRASE.
  # - Empty passphrase: SSL_PASSPHRASE=""     SSL_PASSPHRASE_ENCRYPTED=false
  # - Present:          encrypt via 'accelo admin encrypt' and write unquoted
  #                     SSL_PASSPHRASE=<ciphertext>  SSL_PASSPHRASE_ENCRYPTED=true
  local passphrase_value='""'
  local passphrase_encrypted="false"
  if [ -n "$key_pass" ]; then
    echo -e "${BLUE}→ Encrypting passphrase via 'accelo admin encrypt'...${NC}"
    local encrypt_out encrypted_pass
    encrypt_out=$(printf '%s\n' "$key_pass" | accelo admin encrypt 2>&1) \
      || print_error "accelo admin encrypt failed: $encrypt_out"
    encrypted_pass=$(echo "$encrypt_out" | awk -F'ENCRYPTED: *' '/ENCRYPTED:/ {print $2; exit}' | tr -d '[:space:]')
    if [ -z "$encrypted_pass" ]; then
      print_error "Could not parse ENCRYPTED: output from accelo admin encrypt."
    fi
    passphrase_value="$encrypted_pass"
    passphrase_encrypted="true"
    print_success "Passphrase encrypted (SSL_PASSPHRASE_ENCRYPTED=true)"
  else
    echo -e "${BLUE}→ No passphrase — writing SSL_PASSPHRASE=\"\" and SSL_PASSPHRASE_ENCRYPTED=false${NC}"
  fi

  echo -e "${BLUE}→ Setting SSL_ENFORCED=true, SSL_ENABLED=false, SSL_UI_PORT=$PULSE_PORT${NC}"
  local tmp_yml="$AD_CORE_YML.tmp"
  PASS_VALUE="$passphrase_value" PASS_ENC="$passphrase_encrypted" \
  awk -v svc="$PULSE_SERVICE:" -v port="$PULSE_PORT" '
    BEGIN {
      pass_value = ENVIRON["PASS_VALUE"]
      pass_enc   = ENVIRON["PASS_ENC"]
      ssl_port_seen = 0
      enc_seen      = 0
    }
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
      section = $1
      ssl_port_seen = 0
      enc_seen      = 0
    }
    {
      if (section == svc) {
        # Dedupe SSL_UI_PORT=
        if ($0 ~ /SSL_UI_PORT=/) {
          if (ssl_port_seen) { next }
          ssl_port_seen = 1
          sub(/SSL_UI_PORT=[0-9]+/, "SSL_UI_PORT=" port)
        }
        sub(/SSL_ENFORCED=false/, "SSL_ENFORCED=true")
        sub(/SSL_ENABLED=true/,  "SSL_ENABLED=false")
        if ($0 ~ /SSL_PASSPHRASE_ENCRYPTED=/) {
          if (enc_seen) { next }
          enc_seen = 1
          sub(/SSL_PASSPHRASE_ENCRYPTED=.*/, "SSL_PASSPHRASE_ENCRYPTED=" pass_enc)
        } else if ($0 ~ /SSL_PASSPHRASE=/) {
          sub(/SSL_PASSPHRASE=.*/, "SSL_PASSPHRASE=" pass_value)
          print
          if (!enc_seen) {
            # Emit the encrypted flag right below SSL_PASSPHRASE=
            match($0, /^[[:space:]]*-[[:space:]]/)
            prefix = substr($0, RSTART, RLENGTH)
            print prefix "SSL_PASSPHRASE_ENCRYPTED=" pass_enc
            enc_seen = 1
          }
          next
        }
      }
      print
    }
  ' "$AD_CORE_YML" > "$tmp_yml"
  if [ $? -ne 0 ]; then
    rm -f "$tmp_yml"
    print_error "awk failed to rewrite ad-core.yml."
  fi
  mv "$tmp_yml" "$AD_CORE_YML" || { rm -f "$tmp_yml"; print_error "Failed to move updated ad-core.yml into place."; }
  print_success "SSL_* variables updated in '$PULSE_SERVICE' section"

  local ssl_port_count
  ssl_port_count=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && /SSL_UI_PORT=/ { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$ssl_port_count" -ne 1 ]; then
    print_error "Expected exactly 1 SSL_UI_PORT line in '$PULSE_SERVICE' after update, found $ssl_port_count. Restore from $AD_CORE_YML.bak and investigate."
  fi
  print_success "SSL_UI_PORT appears exactly once in '$PULSE_SERVICE' section"

  echo -e "${BLUE}→ Ensuring ./config/proxy/certs is mounted at /etc/acceldata/ssl inside the container...${NC}"
  local mount_in_section
  mount_in_section=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && /\/config\/proxy\/certs/ { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$mount_in_section" -eq 0 ]; then
    sed -i "/${PULSE_SERVICE}:/,/ulimits:/ s|volumes:|volumes:\n    - ./config/proxy/certs:/etc/acceldata/ssl|" "$AD_CORE_YML" \
      || print_error "Failed to add certs volume mount to $PULSE_SERVICE."
    print_success "Added volume mount: ./config/proxy/certs -> /etc/acceldata/ssl"
  else
    print_info "Volume mount already present in '$PULSE_SERVICE' — nothing to add"
  fi
  echo

  print_header "[8/9] Restarting $PULSE_SERVICE container"
  echo -e "${BLUE}→ Checking current state of '$PULSE_SERVICE'...${NC}"
  local pulse_container
  pulse_container=$(docker ps -a --format '{{.Names}}' | grep -E "^${PULSE_SERVICE}(_|$)" | head -n1)
  if [ -z "$pulse_container" ]; then
    print_warning "Container '$PULSE_SERVICE' not found in 'docker ps -a'."
    print_info    "If Pulse was never deployed, run 'accelo deploy all' before enabling TLS."
    print_error   "Cannot restart a container that does not exist."
  fi
  print_success "Found container: $pulse_container"

  echo -e "${BLUE}→ Running: accelo restart $PULSE_SERVICE${NC}"
  if ! echo "y" | accelo restart "$PULSE_SERVICE"; then
    print_error "Failed to restart $PULSE_SERVICE. Inspect with 'docker logs $pulse_container' and restore $AD_CORE_YML.bak if needed."
  fi
  print_success "Restart command completed"

  echo -e "${BLUE}→ Waiting 10 seconds for $PULSE_SERVICE to come up...${NC}"
  sleep 10
  if ! docker ps --format '{{.Names}}' | grep -qE "^${PULSE_SERVICE}(_|$)"; then
    print_error_soft "$PULSE_SERVICE is not running after restart — check 'docker logs $pulse_container'."
  else
    print_success "$PULSE_SERVICE is running"
  fi
  echo

  print_header "[9/9] Verifying TLS handshake on localhost:$PULSE_PORT"
  echo -e "${BLUE}→ Running openssl s_client against localhost:$PULSE_PORT...${NC}"
  if openssl s_client -connect "localhost:$PULSE_PORT" -showcerts </dev/null 2>/dev/null \
       | openssl x509 -noout -checkend 0 &>/dev/null; then
    print_success "TLS is live and certificate is valid on port $PULSE_PORT"
  else
    print_error_soft "Could not verify TLS on port $PULSE_PORT yet."
    print_info       "The container may still be starting up. Re-check with:"
    print_info       "  openssl s_client -connect localhost:$PULSE_PORT </dev/null"
    print_info       "  docker logs $pulse_container"
  fi
  echo
  echo -e "${GREEN}${TICK} Pulse Web UI is now served over HTTPS.${NC}"
  echo -e "${GREEN}   Access at: https://$host:$PULSE_PORT${NC}"
}

# ---------------------------------------------------------------------------
#  Operational utilities
# ---------------------------------------------------------------------------

# Tar all Pulse container logs (containers whose names start with "ad-")
# into /tmp/ad-container-logs-<date>.tar.gz for support bundles.
function collect_logs {
  local current_date staging archive
  current_date=$(date +%Y-%m-%d)
  archive="/tmp/ad-container-logs-${current_date}.tar.gz"

  # Stage per-container logs in a private tempdir so the final tar doesn't pick
  # up unrelated /tmp/ad-*.log files left behind by other tools or prior runs.
  staging=$(mktemp -d -t ad-container-logs.XXXXXX) || {
    echo -e "${RED}${CROSS} Failed to create staging directory${NC}" >&2
    return 1
  }
  trap 'rm -rf "$staging"' RETURN

  local containers
  containers=$(docker ps --format "{{.Names}}" | grep "^ad-" || true)
  if [ -z "$containers" ]; then
    echo -e "${YELLOW}No ad-* containers running — nothing to collect.${NC}"
    return 0
  fi

  while IFS= read -r container; do
    echo "Collecting logs for container: $container"
    docker logs "$container" > "$staging/$container.log" 2>&1
  done <<< "$containers"

  tar -czf "$archive" -C "$staging" .
  echo -e "${GREEN}Logs collected and tarred at ${NC}${archive}"
}

# Tar all Pulse configuration files (yaml, conf, xml, sh, json, etc.) under
# $AcceloHome into /tmp/acceldata_backup_<timestamp>.tar.gz. Excludes the
# director/ and data/ subdirectories. Sources /etc/profile.d/ad.sh if needed.
#
# Exits:  1 if AcceloHome is unset or the tar step fails
backup_config() {
  # Load AcceloHome from ad.sh if not already set
  if [ -z "${AcceloHome:-}" ] && [ -f /etc/profile.d/ad.sh ]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/ad.sh
  fi

  if [ -z "${AcceloHome:-}" ] || [ ! -d "$AcceloHome" ]; then
    print_error "AcceloHome is not set or does not exist. Cannot perform backup."
  fi

  read -rp "Do you want to take a backup of Pulse related configs (yes/no)? " answer

  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
      echo "Backup operation canceled."
      return 0
      ;;
  esac

  timestamp=$(date +%Y%m%d%H%M%S)
  backup_file="/tmp/acceldata_backup_$timestamp.tar.gz"

  echo "Creating a backup, please wait..."
  if find "$AcceloHome" -type f \( -name "*.conf" -o -name "accelo.log" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.json" -o -name "*.actions" -o -name "*.xml" -o -name ".activecluster" -o -name ".dist" \) \
       | tar --exclude="*/director/*" --exclude="*/data/*" -zcf "$backup_file" -T - ; then
    echo -e "${TICK} Backup completed successfully. Pulse config file: ${GREEN}$backup_file${NC}"
  else
    print_error "Backup failed."
  fi
}

# ---------------------------------------------------------------------------
#  Kerberos helpers
# ---------------------------------------------------------------------------

# Fetch the HDFS keytab and /etc/krb5.conf from a cluster node onto the
# Pulse host so the Pulse containers can authenticate against a kerberized
# Hadoop cluster. Uses interactive ssh/scp password prompts — no sshpass,
# no hardcoded credentials, no private-key handling.
#
# Workflow:
#   1. Prompt for hostname/IP, remote username (default root), management
#      tool (cloudera/ambari), and whether Kerberos is actually enabled.
#   2. If RHEL-family and krb5-workstation is missing, offer to install it
#      locally so `klist` works for verification.
#   3. Discover the HDFS keytab on the remote:
#        Cloudera: newest hdfs.keytab under /var/run/cloudera-scm-agent/process/
#        Ambari:   first *hdfs*.keytab under /etc/security/keytabs/
#   4. scp /etc/krb5.conf + discovered keytab into $AcceloHome/security/
#      (or /tmp/pulse-krb-<ts>/ if AcceloHome is unset).
#   5. Print klist output on the fetched keytab as a sanity check.
#
# The ssh password is typed interactively for each remote command. Using
# ControlMaster multiplexing keeps the prompt to once per invocation.
#
# Exits:
#   87 — invalid yes/no or management-tool input
#    1 — remote discovery empty, scp failed, or krb5-workstation install failed
fetch_krb_files() {
  print_header "Fetching Kerberos files from cluster node..."

  # ---- Step 1: gather inputs ----
  local hostname username management_tool kerberos_enabled
  read -rp "$(echo -e "${YELLOW}▶ IP/hostname of the cluster node${NC}: ")" hostname
  if [ -z "$hostname" ]; then
    print_error "Hostname cannot be empty."
  fi

  read -rp "$(echo -e "${YELLOW}▶ Remote username${NC} ${GREY}[default: root]${NC}: ")" username
  username=${username:-root}

  read -rp "$(echo -e "${YELLOW}▶ Cluster management tool${NC} ${GREEN}[cloudera]${NC}/${GREEN}[ambari]${NC} ${GREY}[default: ambari]${NC}: ")" management_tool
  management_tool=$(echo "$management_tool" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  management_tool=${management_tool:-ambari}
  case "$management_tool" in
    cloudera|ambari) ;;
    *) print_error "Invalid input. Only 'cloudera' or 'ambari' is accepted." ;;
  esac

  read -rp "$(echo -e "${YELLOW}▶ Is Kerberos enabled on the cluster?${NC} ${GREEN}[y]${NC}/${RED}[n]${NC}: ")" kerberos_enabled
  kerberos_enabled=$(echo "$kerberos_enabled" | tr -d '[:space:]\r\n' | tr '[:upper:]' '[:lower:]')
  case "$kerberos_enabled" in
    y|yes) ;;
    n|no)
      print_info "Kerberos not enabled — nothing to copy."
      return 0
      ;;
    *) print_error "Invalid input. Only 'y' or 'n' is accepted." ;;
  esac

  # ---- Step 2: ensure krb5-workstation locally (for klist) ----
  detect_os
  if is_rhel_family && ! command -v klist &>/dev/null; then
    echo -e "${GREY}Installing krb5-workstation (provides klist)...${NC}"
    local pkg_mgr
    pkg_mgr=$(command -v dnf &>/dev/null && echo dnf || echo yum)
    sudo "$pkg_mgr" -y -q install krb5-workstation \
      || print_error "Failed to install krb5-workstation."
  fi

  # ---- Step 3: pick a destination directory ----
  local dest_dir
  if [ -z "${AcceloHome:-}" ] && [ -f /etc/profile.d/ad.sh ]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/ad.sh
  fi
  if [ -n "${AcceloHome:-}" ] && [ -d "$AcceloHome" ]; then
    dest_dir="$AcceloHome/security"
  else
    dest_dir=$(mktemp -d -p /tmp pulse-krb.XXXXXX)
    print_warning "AcceloHome not set; fetching into ${dest_dir}"
  fi
  mkdir -p "$dest_dir" || print_error "Cannot create destination directory: $dest_dir"

  # ---- Step 4: connection-multiplex + force-password auth setup ----
  # Disable pubkey/GSSAPI so ssh goes straight to password/keyboard-interactive
  # prompts. ControlMaster reuses the authenticated socket so the password is
  # typed only once across the discovery ssh + scp.
  local ctl_sock
  ctl_sock=$(mktemp -u -p /tmp "pulse-krb-ctl.XXXXXX")
  local ssh_common=(
    -o ControlMaster=auto
    -o "ControlPath=${ctl_sock}"
    -o ControlPersist=60s
    -o StrictHostKeyChecking=accept-new
    -o PubkeyAuthentication=no
    -o GSSAPIAuthentication=no
    -o "PreferredAuthentications=password,keyboard-interactive"
    -o NumberOfPasswordPrompts=3
  )

  echo -e "${CYAN}Connecting to ${ICyan}${username}@${hostname}${CYAN}...${NC}"
  echo -e "${GREY}  (you will be prompted for the remote password)${NC}"

  # ---- Step 4b: authenticate once up-front so failures are reported clearly ----
  # Runs a trivial `true` over the control-master connection. Subsequent ssh/scp
  # calls then reuse the already-authenticated socket without re-prompting.
  if ! ssh "${ssh_common[@]}" "${username}@${hostname}" true; then
      ssh "${ssh_common[@]}" -O exit "${username}@${hostname}" 2>/dev/null || true
      print_error "SSH authentication to ${username}@${hostname} failed. Check credentials, or confirm the remote sshd allows password auth (PasswordAuthentication yes in /etc/ssh/sshd_config)."
  fi

  # ---- Step 5: discover the HDFS keytab on the remote ----
  local remote_keytab=""
  case "$management_tool" in
    cloudera)
      remote_keytab=$(ssh "${ssh_common[@]}" "${username}@${hostname}" \
        "find /var/run/cloudera-scm-agent/process/ -name 'hdfs.keytab' 2>/dev/null | sort -r | head -n 1")
      ;;
    ambari)
      remote_keytab=$(ssh "${ssh_common[@]}" "${username}@${hostname}" \
        "find /etc/security/keytabs/ -name '*hdfs*.keytab' 2>/dev/null | head -n 1")
      if [ -z "$remote_keytab" ]; then
        # Fallback to conventional Ambari filenames
        remote_keytab=$(ssh "${ssh_common[@]}" "${username}@${hostname}" \
          "ls /etc/security/keytabs/hdfs.headless.keytab /etc/security/keytabs/hdfs.keytab 2>/dev/null | head -n 1")
      fi
      ;;
  esac

  if [ -z "$remote_keytab" ]; then
    ssh "${ssh_common[@]}" -O exit "${username}@${hostname}" 2>/dev/null || true
    print_error "No HDFS keytab found on ${hostname}. Check ${management_tool} setup."
  fi
  echo -e "  ${BLUE}Remote keytab:${NC} ${ICyan}${remote_keytab}${NC}"
  echo -e "  ${BLUE}Remote krb5.conf:${NC} ${ICyan}/etc/krb5.conf${NC}"

  # ---- Step 6: scp both files in one shot (reuses the control socket) ----
  if ! scp "${ssh_common[@]}" \
      "${username}@${hostname}:/etc/krb5.conf" \
      "${username}@${hostname}:${remote_keytab}" \
      "$dest_dir/"; then
    ssh "${ssh_common[@]}" -O exit "${username}@${hostname}" 2>/dev/null || true
    print_error "Failed to copy Kerberos files from ${hostname}."
  fi

  # Tear down the ssh control master
  ssh "${ssh_common[@]}" -O exit "${username}@${hostname}" 2>/dev/null || true

  print_success "Kerberos files copied to ${dest_dir}"
  find "$dest_dir" -maxdepth 1 -type f -printf "  ${GREY}→ %p${NC}\n"

  # ---- Step 7: sanity-check the keytab ----
  local local_keytab
  local_keytab=$(find "$dest_dir" -maxdepth 1 -name "*hdfs*.keytab" -type f 2>/dev/null | head -n 1)
  if [ -n "$local_keytab" ] && command -v klist &>/dev/null; then
    echo
    echo -e "${CYAN}Keytab principals:${NC}"
    klist -kt "$local_keytab" || print_warning "klist failed on $local_keytab"
  fi
}

# ---------------------------------------------------------------------------
#  Command dispatcher
# ---------------------------------------------------------------------------

# Emit a one-line deprecation notice when a renamed command is invoked under
# its legacy name. Only fires when the user actually typed the old name.
#
# Args:   $1 — invoked name, $2 — canonical new name
_deprecated_alias() {
  if [ "$1" != "$2" ]; then
    echo -e "${YELLOW}deprecated: '$1' is now '$2' — old name still works but will be removed${NC}" >&2
  fi
}

case "$1" in
  preflight_os|check_os_prerequisites)
    _deprecated_alias "$1" preflight_os
    preflight_os
    ;;
  preflight_docker|check_docker_prerequisites)
    _deprecated_alias "$1" preflight_docker
    preflight_docker
    ;;
  install_pulse)
    install_pulse
    ;;
  install_pulse_full|full_install_pulse)
    _deprecated_alias "$1" install_pulse_full
    install_pulse_full
    ;;
  configure_truststore|configure_ssl_for_pulse)
    _deprecated_alias "$1" configure_truststore
    configure_truststore
    ;;
  enable_ui_tls|setup_pulse_tls)
    _deprecated_alias "$1" enable_ui_tls
    enable_ui_tls
    ;;
  collect_logs|collect_docker_logs)
    _deprecated_alias "$1" collect_logs
    collect_logs
    ;;
  backup_config|backup_pulse_config)
    _deprecated_alias "$1" backup_config
    backup_config
    ;;
  fetch_krb_files)
    fetch_krb_files
    ;;
  set_docker_data_root)
    set_docker_data_root
    ;;
  -h|--help|help|*)
    show_usage
    ;;
esac
