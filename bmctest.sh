#!/usr/bin/env bash

# version 0.11 of shellcheck is bad with indirect function calls
# shellcheck disable=SC2329

set -eu

# bmctest.sh tests the hosts from the supplied yaml config file
# are working with the required ironic opperations (register, power, virtual media)

# Source common library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

# this is used to skip the tests if we fail to start ironic
SKIP_TESTS="false"
COREOS_BUILDS="https://builds.coreos.fedoraproject.org/streams/stable.json"
# use the upstream ironic image by default
IRONICIMAGE="quay.io/metal3-io/ironic:latest"
IRONICCLIENT="quay.io/metal3-io/ironic-client"
PULL_SECRET=""
# defaults
export HTTP_PORT="8080"
export TIMEOUT="300"
TLS_ENABLE="false"
TLS_PORT=""
LOG_SAVE="on_error"

function usage {
    echo "USAGE:"
    echo "./$(basename "$0") [-i ironic_image] -I interface [-p http_port] [-T tls_port] [-t timeout] [-s pull_secret.json] [-l always] -c config.yaml"
    echo "ironic image defaults to $IRONICIMAGE"
    echo "only specify pull_secret for openshift ironic image, not upstream"
    echo "http_port for virtual media defaults to $HTTP_PORT"
    echo "-T tls_port switches virtual media to HTTPS"
    echo "timeout defaults to $TIMEOUT, it is used in 4 places for each tested machine"
    echo "[-l always] saves the Ironic log even on success (default only on error)"
}

while getopts "i:I:s:c:p:T:t:l:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        i) IRONICIMAGE=$OPTARG ;;
        I) INTERFACE=$OPTARG ;;
        s) PULL_SECRET=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        p) HTTP_PORT=$OPTARG ;;
        T) TLS_PORT=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        l) LOG_SAVE=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ -z ${INTERFACE:-} ]]; then
    echo "ERROR: you must provide the network interface"
    usage
    exit 1
fi

if ! validate_config_file "${CONFIGFILE:-}"; then
    usage
    exit 1
fi

timestamp "validating config structure"
if ! validate_upstream_config "${CONFIGFILE}"; then
    exit 1
fi
HOST_COUNT=$(count_hosts "${CONFIGFILE}" "upstream")
timestamp "found $HOST_COUNT host(s) in config"

if [[ -n $TLS_PORT ]]; then
    TLS_ENABLE="true"
fi

ERROR_LOG=$(mktemp)
export ERROR_LOG
function cleanup {
    timestamp "cleaning up - removing container(s)"
    sudo podman rm -f -t 0 bmctest
    sudo podman rm -f -t 0 bmcicli
    rm -rf "$ERROR_LOG"
    echo -ne "\a" # bell
}
trap "cleanup" EXIT

timestamp "checking / installing dependencies (passwordless sudo, podman, curl, parallel, nc, yq)"
if ! check_sudo; then
    exit 1
fi
ensure_dependencies curl nc podman jq yq parallel

timestamp "checking / getting ISO image"
ISO_URL=$(curl -s "$COREOS_BUILDS" | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')
ISO=$(basename "$ISO_URL")
export ISO
if sudo [ ! -e "/srv/ironic/html/images/${ISO}" ]; then
    sudo mkdir -p /srv/ironic/html/images/
    sudo curl -L "$ISO_URL" -o "/srv/ironic/html/images/${ISO}"
fi

timestamp "checking / cleaning old containers"
sudo podman rm -f -t 0 bmctest
sudo podman rm -f -t 0 bmcicli

timestamp "checking TCP 6385 port for Ironic is not already in use"
if ! check_port_available 6385 "Ironic"; then
    exit 1
fi

timestamp "checking TCP $HTTP_PORT port for http is not already in use"
if ! check_port_available "$HTTP_PORT" "HTTP"; then
    exit 1
fi

if [[ "$TLS_ENABLE" == "true" ]]; then
    timestamp "checking TCP $TLS_PORT port for https is not already in use"
    if ! check_port_available "$TLS_PORT" "HTTPS"; then
        exit 1
    fi
fi


timestamp "starting ironic server container"
sudo podman run --privileged --authfile "$PULL_SECRET" --rm -d --net host \
    --env PROVISIONING_INTERFACE="${INTERFACE}" --env HTTP_PORT="$HTTP_PORT" \
    --env IRONIC_VMEDIA_TLS_SETUP="$TLS_ENABLE" --env VMEDIA_TLS_PORT="$TLS_PORT"  \
    --env OS_CLOUD=bmctest -v /srv/ironic:/shared \
    --name bmctest --entrypoint sleep "$IRONICIMAGE" infinity

# baremetal cli runs in the ironic client container
# it is the upstream version, but it is also used for openshift
timestamp "starting ironic client container"
sudo podman run --privileged --rm -d --net host --env  OS_CLOUD=bmctest \
    --name bmcicli --entrypoint sleep $IRONICCLIENT infinity
sudo podman exec bmcicli bash -c "mkdir -p /etc/openstack"
sudo podman cp clouds.yaml bmcicli:/etc/openstack/clouds.yaml
function bmwrap {
    # Use process-specific cache directory to avoid race condition accessing cache
    local cache_dir
    cache_dir="/tmp/ironic-cache-$$-$(date +%s%N)"
    # shellcheck disable=SC2068
    sudo podman exec -e XDG_CACHE_HOME="$cache_dir" bmcicli baremetal $@ # no quotes, we actually want splitting
}
export -f bmwrap

# starting httpd
timestamp "starting httpd process"
if [[ "$TLS_ENABLE" == "true" ]]; then
    sudo podman exec bmctest bash -c "
        mkdir -p /certs/vmedia && cd /certs/vmedia
        make-dummy-cert bundle
        csplit -f tls --suppress-matched bundle /^$/
        mv tls00 tls.key && chmod 600 tls.key
        mv tls01 tls.crt && rm bundle"
fi
sudo podman exec -d bmctest bash -c "/bin/runhttpd > /tmp/httpd.log 2>&1"

# starting ironic
timestamp "starting ironic process"
if [[ "$TLS_ENABLE" == "true" ]]; then
    sudo podman exec bmctest bash -c "sed -i '2i webserver_verify_ca = False' /etc/ironic/ironic.conf.j2"
fi
sudo podman exec -d bmctest bash -c "runironic > /tmp/ironic.log 2>&1"
sleep 5
if ! sudo podman exec bmctest bash -c "ls -l /proc/*/exe | grep -q python3"; then
    echo "no python3 process inside container, looks like ironic failed to start, not running tests, check log" >> "$ERROR_LOG"
    SKIP_TESTS="true"
fi

# Function to wait for Ironic API to be available
function wait_for_ironic_api {
    local max_attempts=$TIMEOUT  # Check every 1 second
    local attempt=1

    echo "    checking API availability (timeout: ${TIMEOUT}s)"
    while [ $attempt -le "$max_attempts" ]; do
        if curl -s -f http://localhost:6385/v1 >/dev/null 2>&1; then
            echo "    API available after $attempt seconds"
            return 0
        fi
        echo -n "."
        sleep 1
        attempt=$((attempt + 1))
    done
    echo
    echo "    API not available after ${TIMEOUT} seconds"
    return 1
}
export -f wait_for_ironic_api

# Function to get Ironic version
function get_ironic_version {
    local version
    # Get version from API (should be available now)
    version=$(curl -s http://localhost:6385/v1 2>/dev/null | jq -r '.version.version // .default_version.version // empty' 2>/dev/null)
    if [[ -n "$version" && "$version" != "null" ]]; then
        echo "$version"
        return
    fi
    # Fallback to container version or image name
    version=$(sudo podman exec bmctest python3 -c "import ironic; print(ironic.__version__)" 2>/dev/null)
    echo "${version:-$IRONICIMAGE}"
}
export -f get_ironic_version

# Function to get BMC firmware version via Redfish
function get_bmc_firmware_version {
    local protocol=$1 address=$2 systemid=$3 user=$4 pass=$5
    local base_url="${protocol}://${address}"
    local version
    local manager_path

    # Try to get Manager link from System, then try common paths
    manager_path=$(curl -sk -u "${user}:${pass}" "${base_url}${systemid}" 2>/dev/null | \
        jq -r '.Links.Managers[0]["@odata.id"] // empty' 2>/dev/null)

    # Try manager paths in order: linked, then vendor-specific, then common defaults
    for path in "$manager_path" "/redfish/v1/Managers/iDRAC.Embedded.1" "/redfish/v1/Managers/1" "/redfish/v1/Managers/iLO.Integrated.1" "/redfish/v1/Managers/BMC"; do
        [[ -z "$path" || "$path" == "null" ]] && continue
        version=$(curl -sk -u "${user}:${pass}" "${base_url}${path}" 2>/dev/null | \
            jq -r '.FirmwareVersion // empty' 2>/dev/null)
        [[ -n "$version" && "$version" != "null" ]] && echo "$version" && return
    done

    echo "unknown"
}
export -f get_bmc_firmware_version

# Wait for Ironic API to be available
timestamp "waiting for Ironic API to be available"
if ! wait_for_ironic_api; then
    echo "ERROR: Ironic API failed to become available within timeout" >> "$ERROR_LOG"
    SKIP_TESTS="true"
else
    timestamp "capturing Ironic version"
    IRONIC_VERSION=$(get_ironic_version)
    echo "Ironic Version: $IRONIC_VERSION"
    echo
fi

function test_manage {
    local name=$1; local boot=$2; local protocol=$3; local address=$4; local systemid=$5; local user=$6; local pass=$7; local insecure=$8
    case $insecure in
        null | False | false | no | No)
            local verify_ca="True"
            ;;
        yes | Yes | True | true)
            local verify_ca="False"
            ;;
    esac
    local redfish_info="
        --driver-info redfish_address=${protocol}://${address} --driver-info redfish_system_id=${systemid}
        --driver-info redfish_username=${user} --driver-info redfish_password=${pass}
        --driver-info redfish_verify_ca=${verify_ca}"
    local idrac_info="
        ${redfish_info}
        --driver-info drac_address=${address} --driver-info drac_username=${user} --driver-info drac_password=${pass}
        --bios-interface idrac-redfish --management-interface idrac-redfish --power-interface idrac-redfish
        --raid-interface idrac-redfish --vendor-interface idrac-redfish"
    local ilo5_info="
        --driver-info ilo_address=${address} --driver-info ilo_username=${user} --driver-info ilo_password=${pass}
        --driver-info ilo_verify_ca=${verify_ca}
        --driver-info deploy_kernel='http://example.com/kernel' --driver-info deploy_ramdisk='http://example.com/ramdisk'"
        # ilo5 driver checks for kernel and ramdisk are set even if no automated clean, must be a bug
    case $boot in
        # see https://github.com/openshift/baremetal-operator/blob/master/docs/api.md
        idrac-virtualmedia)
            local driver="idrac"; local driver_info=$idrac_info ;;
        redfish-virtualmedia)
            local driver="redfish"; local driver_info=$redfish_info ;;
        ilo5-virtualmedia)
            local driver="ilo5"; local driver_info=$ilo5_info ;;
        *)
            echo "unsupported boot method \"$boot\" for $name" >> "$ERROR_LOG"
            return 1
    esac
    bmwrap node create --driver "$driver" "$driver_info" --property capabilities='boot_mode:uefi' --name "$name" > /dev/null
    echo -n "    " # indent baremetal output
    if ! bmwrap node manage "$name" --wait "$TIMEOUT"; then
        echo "can not manage node $name" >> "$ERROR_LOG"
        return 1
    fi
}
export -f test_manage

function test_power {
    local name=$1
    for power in on off; do
        sleep 10
        if ! bmwrap node power "$power" "$name" --power-timeout "$TIMEOUT"; then
            echo "can not power $power ${name}" >> "$ERROR_LOG"
            return 1
        fi
    done
}
export -f test_power

function test_boot_vmedia {
    local name=$1; local boot=$2
    case $boot in
        idrac-virtualmedia)
            local boot_if="idrac-redfish-virtual-media" ;;
        redfish-virtualmedia)
            local boot_if="redfish-virtual-media" ;;
        ilo5-virtualmedia)
            local boot_if="ilo-virtual-media" ;;
        *)
            echo "unknown boot method \"$boot\" for $name" >> "$ERROR_LOG"
            return 1
    esac
    local ip
    ip=$(ip route get 1.1.1.1 | awk '{printf $7}')
    bmwrap node set "$name" --boot-interface "$boot_if" --deploy-interface ramdisk \
        --instance-info boot_iso="http://${ip}:${HTTP_PORT}/images/${ISO}"
    bmwrap node set "$name" --no-automated-clean
    echo -n "    " # indent baremetal output
    bmwrap node provide --wait "$TIMEOUT" "$name"
    echo -n "    " # indent baremetal output
    if ! bmwrap node deploy --wait "$TIMEOUT" "$name"; then
        echo "failed to boot node $name from ISO" >> "$ERROR_LOG"
        return 1
    fi
}
export -f test_boot_vmedia

function test_boot_device {
    local name=$1
    if ! bmwrap node boot device set "$name" pxe; then
        echo "failed to switch boot device to PXE on $name" >> "$ERROR_LOG"
        return 1
    fi
}
export -f test_boot_device

function test_eject_media {
   local name=$1; local boot=$2
   if [[ $boot = "ilo5-virtualmedia" ]]; then
       echo "WARNING: ilo5 does not support eject vmedia, not testing"
       return 0
   fi
   if ! bmwrap node passthru call "$name" eject_vmedia; then
        echo "failed to eject media on $name" >> "$ERROR_LOG"
        return 1
    fi
}
export -f test_eject_media

function test_node {
    local name=$1; local boot=$2; local protocol=$3; local address=$4; local systemid=$5; local user=$6; local pass=$7; local insecure=$8
    echo; echo "===== $name ====="

    timestamp "capturing BMC firmware version for $name"
    local bmc_fw_version
    bmc_fw_version=$(get_bmc_firmware_version "$protocol" "$address" "$systemid" "$user" "$pass")
    echo "    BMC Firmware Version: $bmc_fw_version"
    echo

    timestamp "attempting to manage $name (check address, credentials, certificates)"
    if test_manage "$name" "$boot" "$protocol" "$address" "$systemid" "$user" "$pass" "$insecure"; then
       echo "    success"
    else
       echo "    failed to manage $name - can not run further tests on node"
       return 0
    fi
    sleep 10

    timestamp "testing ability to power on/off $name"
    if test_power "$name"; then
        echo "    success"
    fi
    sleep 10

    timestamp "verifying node boot device can be set on $name"
    if test_boot_device "$name"; then
        echo "    success"
    fi
    sleep 10

    timestamp "testing booting from redfish-virtual-media on $name"
    if test_boot_vmedia "$name" "$boot"; then
        echo "    success"
    fi
    sleep 30

    timestamp "testing vmedia detach on $name"
    if test_eject_media "$name" "$boot"; then
        echo "    success"
    fi
}
export -f test_node

if [[ "$SKIP_TESTS" = "false" ]]; then
    timestamp "testing, can take several minutes, please wait for results ..."
    yq -r '.hosts[] | "\(.name) \(.bmc.boot) \(.bmc.protocol) \(.bmc.address) \(.bmc.systemid) \(.bmc.username) \(.bmc.password) \(.bmc.insecure)"' \
    "$CONFIGFILE" | parallel --colsep ' ' -a - test_node
fi

EXIT=$(wc -l "$ERROR_LOG" | cut -d ' '  -f 1)
echo; echo "========== Found $EXIT errors =========="
cat "$ERROR_LOG"
echo
echo "========== Version Information =========="
echo "Ironic Version: $IRONIC_VERSION"
echo "Ironic Image: $IRONICIMAGE"
echo
logf="ironic_$(date +%Y-%m-%d_%H-%M).log"
if ! [ "$EXIT" -eq 0 ]; then
    echo; echo "Errors found, saving container logs as $logf"
    sudo podman cp bmctest:/tmp/ironic.log "./$logf"
else
    if [ "$LOG_SAVE" = "always" ]; then
        echo; echo "Saving log on success as $logf"
        sudo podman cp bmctest:/tmp/ironic.log "./$logf"
    fi
fi
exit "$EXIT"
