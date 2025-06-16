#!/usr/bin/env bash

set -eu

# intermediate script to parse install-config.yaml,
# create the ironic image from openshift release and then call bmctest.sh

# defaults
RELEASE="4.18"
PULL_SECRET="/opt/dev-scripts/pull_secret.json"
HTTP_PORT="8080"
TLS_PORT="false"
TIMEOUT="300"
LOG_SAVE="on_error"

function usage {
    echo "USAGE:"
    echo "./$(basename "$0") [-r release_version] [-p http_port] [-T tls_port] [-s pull_secret] [-t timeout] [-l always] -c install-config.yaml"
    echo "release version defaults to $RELEASE"
    echo "http_port for virtual media defaults to $HTTP_PORT"
    echo "-T tls_port switches virtual media to HTTPS"
    echo "pull_secret defaults to $PULL_SECRET"
    echo "timeout defaults to $TIMEOUT, it is used in 4 places for each tested machine"
    echo "[-l always] saves the Ironic log even on success (default only on error)"
}

while getopts "r:p:T:s:t:c:l:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        r) RELEASE=$OPTARG ;;
        p) HTTP_PORT=$OPTARG ;;
        T) TLS_PORT=$OPTARG ;;
        s) PULL_SECRET=$OPTARG ;;
        t) TIMEOUT=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        l) LOG_SAVE=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ ! -e ${CONFIGFILE:-} ]]; then
    echo "ERROR: config file \"${CONFIGFILE:-}\" does not exist"
    usage
    exit 1
fi

if [[ ! -e ${PULL_SECRET:-} ]]; then
    echo "ERROR: pull secret file \"${PULL_SECRET:-}\" does not exist"
    usage
    exit 1
fi

function timestamp {
    echo -n "$(date +%T) "
    echo "$1"
}

timestamp "checking/installing dependencies (passwordless sudo, yq, curl, podman)"
if ! sudo true; then
    echo "ERROR: passwordless sudo not available"
    exit 1
fi
for dep in curl jq yq podman; do
    if ! command -v $dep > /dev/null 2>&1; then
        sudo dnf install -y curl jq podman python3-pip
        python3 -m pip install yq
        break
    fi
done

timestamp "getting the release image url"
# shellcheck disable=SC2001
MAJORV=$(echo "$RELEASE" | sed 's/\(^[0-9]\+\).*/\1/')
LATESTTXT="https://mirror.openshift.com/pub/openshift-v${MAJORV}/clients/ocp-dev-preview/latest-${RELEASE}/release.txt"
CANDIDTXT="https://mirror.openshift.com/pub/openshift-v${MAJORV}/clients/ocp-dev-preview/candidate-${RELEASE}/release.txt"
if ! RELEASEIMAGE=$(curl -s "$LATESTTXT" | grep -o 'quay.io/openshift-release-dev/ocp-release.*'); then
    if ! RELEASEIMAGE=$(curl -s "$CANDIDTXT" | grep -o 'quay.io/openshift-release-dev/ocp-release.*'); then
        echo "ERROR: could not find release image url for $RELEASE"
        exit 1
    fi
fi

timestamp "creating the ironic image"
IRONICIMAGE=$(podman run --authfile "$PULL_SECRET" --rm "$RELEASEIMAGE" image ironic)

INPUTFILE=$(mktemp)
function cleanup {
    rm -rf "$INPUTFILE"
}
trap "cleanup" EXIT

timestamp "extracting the provisioning interface from $CONFIGFILE"
INTERFACE=$(yq -r '.platform.baremetal.provisioningBridge' "$CONFIGFILE")
if [[ -z "$INTERFACE" || $INTERFACE = "null" ]]; then
    timestamp "WARNING: found no provision interface in config, defaulting to 'externalBridge'"
    INTERFACE=$(yq -r '.platform.baremetal.externalBridge' "$CONFIGFILE")
fi

timestamp "extracting the hosts from $CONFIGFILE"
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
        }]}' "$CONFIGFILE" > "$INPUTFILE"

timestamp "calling bmctest.sh"
"$(dirname "$0")"/bmctest.sh -i "$IRONICIMAGE" -I "$INTERFACE" -p "$HTTP_PORT" -T "$TLS_PORT" -t "$TIMEOUT" -s "$PULL_SECRET" -l "$LOG_SAVE" -c "$INPUTFILE"
