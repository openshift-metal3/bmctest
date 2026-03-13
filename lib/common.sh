#!/usr/bin/env bash

# common.sh - Shared functions for bmctest
# This library provides common utilities used by both bmctest.sh and ocpbmctest.sh

export BMCTEST_VERSION="0.2.0"

# Print timestamped messages
function timestamp {
    echo -n "$(date +%T) "
    echo "$1"
}

# Check if passwordless sudo is available
function check_sudo {
    if ! sudo true; then
        echo "ERROR: passwordless sudo not available"
        return 1
    fi
}

# Ensure all required dependencies are installed
# Usage: ensure_dependencies
function ensure_dependencies {
    local deps=(curl nc podman jq yq parallel)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" > /dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        timestamp "installing missing dependencies: ${missing[*]}"
        sudo dnf install -y curl jq podman python3-pip parallel nc
        python3 -m pip install yq
        echo "will cite" | parallel --citation > /dev/null 2>&1 || true
    fi
}

# Validate that a file exists
# Usage: validate_file_exists path/to/file "description"
function validate_file_exists {
    local file=$1
    local description=${2:-"file"}
    if [[ ! -e ${file:-} ]]; then
        echo "ERROR: ${description} \"${file:-}\" does not exist"
        return 1
    fi
    return 0
}

# Check if a TCP port is available (not in use)
# Usage: check_port_available port service_name
function check_port_available {
    local port=$1
    local service=$2
    if nc -z localhost "$port" 2>/dev/null; then
        echo "ERROR: ${service} port ${port} already in use"
        return 1
    fi
    return 0
}

# Debug logging - only prints if BMCTEST_DEBUG is set
# Usage: debug_log "message"
function debug_log {
    if [[ "${BMCTEST_DEBUG:-0}" == "1" ]]; then
        echo "[DEBUG $(date +%T)] $*" >&2
    fi
}

# Export functions for use in subshells (e.g., parallel)
export -f timestamp
export -f debug_log
