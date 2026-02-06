#!/usr/bin/env bash

set -eu

# intermediate script to parse install-config.yaml,
# create the ironic image from openshift release and then call bmctest.sh

# Source common library functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

# defaults
RELEASE="4.18"
PULL_SECRET="/opt/dev-scripts/pull_secret.json"
HTTP_PORT="8080"
TLS_PORT=""
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

if ! validate_config_file "${CONFIGFILE:-}"; then
    usage
    exit 1
fi

if ! validate_file_exists "${PULL_SECRET:-}" "pull secret file"; then
    usage
    exit 1
fi

timestamp "checking/installing dependencies (passwordless sudo, yq, curl, podman)"
if ! check_sudo; then
    exit 1
fi
ensure_dependencies curl jq yq podman

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

timestamp "validating OpenShift config structure"
if ! validate_ocp_config "$CONFIGFILE"; then
    exit 1
fi

timestamp "extracting the provisioning interface from $CONFIGFILE"
if ! INTERFACE=$(get_ocp_interface "$CONFIGFILE"); then
    exit 1
fi
HOST_COUNT=$(count_hosts "$CONFIGFILE" "ocp")
timestamp "found $HOST_COUNT host(s) in config, using interface: $INTERFACE"

timestamp "transforming config to upstream format"
if ! transform_ocp_to_upstream "$CONFIGFILE" "$INPUTFILE"; then
    exit 1
fi

if [[ "${BMCTEST_DEBUG:-0}" == "1" ]]; then
    debug_log "Transformed config:"
    cat "$INPUTFILE" >&2
fi

timestamp "validating transformed config"
if ! validate_upstream_config "$INPUTFILE"; then
    echo "ERROR: Config transformation failed validation"
    exit 1
fi

timestamp "calling bmctest.sh"
"$(dirname "$0")"/bmctest.sh -i "$IRONICIMAGE" -I "$INTERFACE" -p "$HTTP_PORT" -T "$TLS_PORT" -t "$TIMEOUT" -s "$PULL_SECRET" -l "$LOG_SAVE" -c "$INPUTFILE"
