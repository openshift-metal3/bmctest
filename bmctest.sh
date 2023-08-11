#!/usr/bin/env bash

set -eu

# bmctest.sh tests the hosts from the supplied yaml config file
# are working with the required ironic opperations (register, power, virtual media)

# this is used to skip the tests if we fail to start ironic
SKIP_TESTS="false"
# FIXME stable URL?
export ISO="fedora-coreos-37.20230205.3.0-live.x86_64.iso"
ISO_URL="https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/37.20230205.3.0/x86_64/$ISO"
# use the upstream ironic image by default
IRONICIMAGE="quay.io/metal3-io/ironic:latest"
IRONICCLIENT="quay.io/metal3-io/ironic-client"
PULL_SECRET=""
# defaults
export HTTP_PORT="8080"
export TLS_PORT="false"
export TIMEOUT="120"

function usage {
    echo "USAGE:"
    echo "./$(basename "$0") [-i ironic_image] -I interface [-p http_port] [-T tls_port] [-t timeout] [-s pull_secret.json] -c config.yaml"
    echo "ironic image defaults to $IRONICIMAGE"
    echo "only specify pull_secret for openshift ironic image, not upstream"
    echo "http_port for virtual media defaults to $HTTP_PORT"
    echo "-T tls_port switches virtual media to HTTPS"
    echo "timeout defaults to $TIMEOUT, it is used in 4 places for each tested machine"
}

while getopts "i:I:s:c:p:T:t:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        i) IRONICIMAGE=$OPTARG ;;
        I) INTERFACE=$OPTARG ;;
        s) PULL_SECRET=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        p) HTTP_PORT=$OPTARG ;;
        T) TLS_PORT=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ -z ${INTERFACE:-} ]]; then
    echo "you must provide the network interface"
    usage
    exit 1
fi

if [[ ! -e ${CONFIGFILE:-} ]]; then
    echo "invalid config file $CONFIGFILE"
    usage
    exit 1
fi

function timestamp {
    echo -n "$(date +%T) "
    echo "$1"
}
export -f timestamp

ERROR_LOG=$(mktemp)
export ERROR_LOG
function cleanup {
    timestamp "cleaning up - removing container(s)"
    sudo podman rm -f -t 0 bmctest
    sudo podman rm -f -t 0 bmcicli
    rm -rf "$ERROR_LOG"
}
trap "cleanup" EXIT

timestamp "checking / installing dependencies (passwordless sudo, podman, curl, parallel, nc, yq)"
if ! sudo true; then
    echo "ERROR: passwordless sudo not available"
    exit 1
fi
for dep in curl nc podman jq yq parallel; do
    if ! command -v $dep > /dev/null 2>&1; then
        sudo dnf install -y curl nc jq podman python3-pip parallel
        python3 -m pip install yq
        echo "will cite" | parallel --citation > /dev/null 2>&1 || true
        break
    fi
done

timestamp "checking / getting ISO image"
if sudo [ ! -e /srv/ironic/html/images/${ISO} ]; then
    sudo mkdir -p /srv/ironic/html/images/
    sudo curl -L $ISO_URL -o /srv/ironic/html/images/${ISO}
fi

timestamp "checking / cleaning old containers"
sudo podman rm -f -t 0 bmctest
sudo podman rm -f -t 0 bmcicli

timestamp "checking TCP 6385 port for Ironic is not already in use"
if nc -z localhost 6385; then
    echo "ERROR: Ironic port already in use, exiting"
    exit 1
fi

timestamp "checking TCP $HTTP_PORT port for http is not already in use"
if nc -z localhost "$HTTP_PORT"; then
    echo "ERROR: http port already in use, exiting"
    exit 1
fi

if [[ "$TLS_PORT" != "false" ]]; then
    timestamp "checking TCP $TLS_PORT port for https is not already in use"
    if nc -z localhost "$TLS_PORT"; then
        echo "ERROR: https port already in use, exiting"
        exit 1
    fi
fi


timestamp "starting ironic server container"
sudo podman run --privileged --authfile "$PULL_SECRET" --rm -d --net host \
    --env PROVISIONING_INTERFACE="${INTERFACE}" --env HTTP_PORT="$HTTP_PORT" \
    --env IRONIC_VMEDIA_TLS_SETUP="$TLS_PORT" --env VMEDIA_TLS_PORT="$TLS_PORT"  \
    --env OS_CLOUD=bmctest -v /srv/ironic:/shared --name bmctest \
    --entrypoint sleep "$IRONICIMAGE" infinity

# baremetal cli runs either in the ironic server or ironic client container
# depending if we run openshift or upstream ironic
if [[ -z "$PULL_SECRET" ]]; then
    timestamp "starting ironic client container"
    sudo podman run --privileged --rm -d --net host --env  OS_CLOUD=bmctest \
        --name bmcicli --entrypoint sleep $IRONICCLIENT infinity
    sudo podman exec bmcicli bash -c "mkdir -p /etc/openstack"
    sudo podman cp clouds.yaml bmcicli:/etc/openstack/clouds.yaml
    function bmwrap {
        sudo podman exec bmcicli baremetal $@ # no quotes, we actually want splitting
    }
else
    sudo podman exec bmctest bash -c "mkdir -p /etc/openstack"
    sudo podman cp clouds.yaml bmctest:/etc/openstack/clouds.yaml
    # FIXME python depreciation warnings inside container
    sudo podman exec bmctest bash -c "echo -e '#!/usr/bin/env bash\npython3 -W ignore /usr/bin/baremetal \$@' > /usr/local/bin/bm"
    sudo podman exec bmctest bash -c "chmod +x /usr/local/bin/bm"
    function bmwrap {
        sudo podman exec bmctest bm "$@"
    }
fi
export -f bmwrap

# starting httpd
timestamp "starting httpd process"
if [[ "$TLS_PORT" != "false" ]]; then
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
if [[ "$TLS_PORT" != "false" ]]; then
    sudo podman exec bmctest bash -c "sed -i '2i webserver_verify_ca = False' /etc/ironic/ironic.conf.j2"
fi
sudo podman exec -d bmctest bash -c "runironic > /tmp/ironic.log 2>&1"
sleep 5
if ! sudo podman exec bmctest bash -c "ls -l /proc/*/exe | grep -q python3"; then
    echo "no python3 process inside container, looks like ironic failed to start, not running tests, check log" >> "$ERROR_LOG"
    SKIP_TESTS="true"
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
    local protocol; local port
    if [[ "$TLS_PORT" != "false" ]]; then
        protocol="https"; port="$TLS_PORT"
    else
        protocol="http"; port="$HTTP_PORT"
    fi
    bmwrap node set "$name" --boot-interface "$boot_if" --deploy-interface ramdisk \
        --instance-info boot_iso="${protocol}://${ip}:${port}/images/${ISO}"
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

    timestamp "attempting to manage $name (check address, credentials, certificates)"
    if test_manage "$name" "$boot" "$protocol" "$address" "$systemid" "$user" "$pass" "$insecure"; then
       echo "    success"
    else
       echo "    failed to manage $name - can not run further tests on node"
       return 0
    fi

    timestamp "verifying node boot device can be set on $name"
    if test_boot_device "$name"; then
        echo "    success"
    fi

    timestamp "testing booting from redfish-virtual-media on $name"
    if test_boot_vmedia "$name" "$boot"; then
        echo "    success"
    fi

    timestamp "testing vmedia detach on $name"
    if test_eject_media "$name" "$boot"; then
        echo "    success"
    fi

    timestamp "testing ability to power on/off $name"
    if test_power "$name"; then
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
if ! [ "$EXIT" -eq 0 ]; then
    logf="ironic.log_$(date +%Y-%m-%d_%H-%M)"
    echo; echo "Errors found, saving container logs as $logf"
    sudo podman cp bmctest:/tmp/ironic.log "./$logf"
fi
exit "$EXIT"
