#!/usr/bin/env bash

# common.sh - Shared functions for bmctest
# This library provides common utilities used by both bmctest.sh and ocpbmctest.sh

export BMCTEST_VERSION="0.1.0"

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
# Usage: ensure_dependencies dep1 dep2 dep3...
function ensure_dependencies {
    local deps=("$@")
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
        # Accept parallel citation notice
        echo "will cite" | parallel --citation > /dev/null 2>&1 || true
        return 0
    fi
    
    return 0
}

# Validate that a config file exists
# Usage: validate_config_file path/to/config.yaml
function validate_config_file {
    local config=$1
    if [[ ! -e ${config:-} ]]; then
        echo "ERROR: config file \"${config:-}\" does not exist"
        return 1
    fi
    return 0
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

# Validate numeric parameter
# Usage: validate_numeric value "parameter_name"
function validate_numeric {
    local value=$1
    local name=$2
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${name} must be numeric, got: ${value}"
        return 1
    fi
    return 0
}

# Print a section header for better log readability
# Usage: print_section "Section Title"
function print_section {
    local title=$1
    echo
    echo "=========================================="
    echo "$title"
    echo "=========================================="
}

# Check if running as root (should not be)
function check_not_root {
    if [[ $EUID -eq 0 ]]; then
        echo "ERROR: This script should not be run as root"
        echo "       Run as a regular user with passwordless sudo"
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

# Validate OpenShift install-config.yaml structure
# Usage: validate_ocp_config path/to/install-config.yaml
function validate_ocp_config {
    local config=$1
    
    debug_log "Validating OpenShift config structure"
    
    # Check for required platform.baremetal section
    if ! yq -e '.platform.baremetal' "$config" >/dev/null 2>&1; then
        echo "ERROR: config missing platform.baremetal section"
        return 1
    fi
    
    # Check for provisioning interface
    local interface
    interface=$(yq -r '.platform.baremetal.provisioningBridge // .platform.baremetal.externalBridge // empty' "$config")
    if [[ -z "$interface" || "$interface" == "null" ]]; then
        echo "ERROR: config missing provisioningBridge or externalBridge"
        return 1
    fi
    
    # Check for hosts
    local host_count
    host_count=$(yq -r '.platform.baremetal.hosts | length' "$config" 2>/dev/null || echo "0")
    if [[ "$host_count" -eq 0 ]]; then
        echo "ERROR: config has no hosts defined"
        return 1
    fi
    
    debug_log "OpenShift config validation passed: $host_count host(s) found"
    return 0
}

# Validate upstream bmctest config.yaml structure
# Usage: validate_upstream_config path/to/config.yaml
function validate_upstream_config {
    local config=$1
    
    debug_log "Validating upstream config structure"
    
    # Check for hosts section
    if ! yq -e '.hosts' "$config" >/dev/null 2>&1; then
        echo "ERROR: config missing hosts section"
        return 1
    fi
    
    # Check for hosts
    local host_count
    host_count=$(yq -r '.hosts | length' "$config" 2>/dev/null || echo "0")
    if [[ "$host_count" -eq 0 ]]; then
        echo "ERROR: config has no hosts defined"
        return 1
    fi
    
    # Validate each host has required BMC fields
    local invalid_hosts
    invalid_hosts=$(yq -r '.hosts[] | select(.bmc.address == null or .bmc.username == null) | .name // "unnamed"' "$config" 2>/dev/null)
    if [[ -n "$invalid_hosts" ]]; then
        echo "ERROR: hosts missing required BMC fields: $invalid_hosts"
        return 1
    fi
    
    debug_log "Upstream config validation passed: $host_count host(s) found"
    return 0
}

# Export functions for use in subshells (e.g., parallel)
export -f timestamp
export -f debug_log
