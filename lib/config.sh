#!/usr/bin/env bash

# config.sh - Configuration parsing and validation functions for bmctest

# Transform OpenShift install-config.yaml to upstream format
# Usage: transform_ocp_to_upstream input.yaml output.yaml
function transform_ocp_to_upstream {
    local input=$1
    local output=$2

    debug_log "Transforming OpenShift config to upstream format"

    yq -y '{hosts: [.platform.baremetal.hosts[] | {
        name,
        bmc: {
            boot: (.bmc.address | capture("(?<boot>[^+:]+)")).boot,
            protocol: (.bmc.address | if test("\\+(?<proto>[^:]+)") then (. | capture("\\+(?<proto>[^:]+)")).proto else "https" end),
            address: (.bmc.address | capture("://(?<addr>[^/]+)")).addr,
            systemid: (.bmc.address | capture("://(?<addr>[^/]+)(?<path>/.*$)")).path,
            username: .bmc.username,
            password: .bmc.password,
            insecure: .bmc.disableCertificateVerification }
        }]}' "$input" > "$output"

    local result=$?
    if [[ $result -ne 0 ]]; then
        echo "ERROR: Failed to transform config"
        return 1
    fi

    debug_log "Config transformation completed"
    return 0
}

# Extract provisioning interface from OpenShift config
# Usage: get_ocp_interface config.yaml
function get_ocp_interface {
    local config=$1
    local interface

    interface=$(yq -r '.platform.baremetal.provisioningBridge' "$config")
    if [[ -z "$interface" || "$interface" = "null" ]]; then
        echo "WARNING: no provisioningBridge in config, defaulting to externalBridge" >&2
        interface=$(yq -r '.platform.baremetal.externalBridge' "$config")
    fi

    if [[ -z "$interface" || "$interface" = "null" ]]; then
        echo "ERROR: No provisioning interface found in config" >&2
        return 1
    fi

    echo "$interface"
}

# Count hosts in config
# Usage: count_hosts config.yaml format
# format: 'ocp' or 'upstream'
function count_hosts {
    local config=$1
    local format=$2
    local count

    case $format in
        ocp)
            count=$(yq -r '.platform.baremetal.hosts | length' "$config" 2>/dev/null || echo "0")
            ;;
        upstream)
            count=$(yq -r '.hosts | length' "$config" 2>/dev/null || echo "0")
            ;;
        *)
            echo "0"
            return 1
            ;;
    esac

    echo "$count"
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

