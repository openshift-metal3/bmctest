#!/usr/bin/env bash

set -eu

# intermediate script to parse install-config.yaml,
# create the ironic image from openshift release and then call bmctest.sh

# defaults
RELEASE="4.13"
PULL_SECRET="/opt/dev-scripts/pull_secret.json"
HTTP_PORT="6380"

function usage {
    echo "USAGE:"
    echo "./$(basename "$0") [-r release_version] [-p http_port] [-s pull_secret] -c install-config.yaml"
    echo "release version defaults to $RELEASE"
    echo "http_port defaults to $HTTP_PORT"
    echo "pull_secret defaults to $PULL_SECRET"
}

while getopts "r:p:s:c:h" opt; do
    case $opt in
        h) usage; exit 0 ;;
        r) RELEASE=$OPTARG ;;
        p) HTTP_PORT=$OPTARG ;;
        s) PULL_SECRET=$OPTARG ;;
        c) CONFIGFILE=$OPTARG ;;
        ?) usage; exit 1 ;;
    esac
done

if [[ ! -e ${CONFIGFILE:-} ]]; then
    echo "invalid config file"
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
for dep in curl yq podman; do
    if ! command -v $dep > /dev/null 2>&1; then
        sudo dnf install -y curl podman python3-pip
        python3 -m pip install yq
        break
    fi
done

timestamp "getting the release image url"
RELEASEIMAGE=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp-dev-preview/latest-"${RELEASE}"/release.txt \
    | grep -o 'quay.io/openshift-release-dev/ocp-release.*')


# upstream version will use a metal3 ironic image
timestamp "creating the ironic image"
IRONICIMAGE=$(podman run --rm "$RELEASEIMAGE" image ironic)

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
"$(dirname "$0")"/bmctest.sh -i "$IRONICIMAGE" -I "$INTERFACE" -p "$HTTP_PORT" -s "$PULL_SECRET" -c "$INPUTFILE"
