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

# Validate BMC address format
# Usage: validate_bmc_address "address"
function validate_bmc_address {
    local address=$1
    
    # Should match: boot-method+protocol://address/path or protocol://address/path
    if [[ ! "$address" =~ ^([a-z0-9-]+\+)?(https?|redfish|idrac|ilo5)://[^/]+ ]]; then
        echo "ERROR: Invalid BMC address format: $address"
        return 1
    fi
    
    return 0
}

export -f transform_ocp_to_upstream
export -f get_ocp_interface
export -f count_hosts
export -f validate_bmc_address
