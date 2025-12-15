# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

bmctest validates that Baseboard Management Controllers (BMCs) are compatible with OpenStack Ironic. It tests critical BMC operations: node registration, power management, boot device configuration, virtual media mounting/booting, and media ejection.

## Running Tests

### OpenShift Workflow
```bash
./ocpbmctest.sh -c install-config.yaml
# Optional flags:
# -r 4.18                    # OpenShift release version (default: 4.18)
# -p 8080                    # HTTP port for virtual media (default: 8080)
# -T 8443                    # Enable HTTPS virtual media on specified port
# -s /path/to/pull_secret    # Pull secret (default: /opt/dev-scripts/pull_secret.json)
# -t 300                     # Timeout in seconds (default: 300)
# -l always                  # Save Ironic log even on success (default: on_error)
```

### Upstream Ironic Workflow
```bash
./bmctest.sh -I eth0 -c config.yaml
# Required: -I interface, -c config.yaml
# Optional flags same as above except -r
# -i quay.io/metal3-io/ironic:latest  # Custom ironic image
```

### Exit Codes
Exit code equals the number of errors encountered. Zero means all tests passed.

## Development Commands

### Linting
```bash
shellcheck bmctest.sh ocpbmctest.sh
# Configuration: .shellcheckrc disables SC2317 (parallel/trap false positives)
```

### Manual Container Testing
```bash
# Start containers manually for debugging:
sudo podman run --privileged --rm -d --net host \
  --env PROVISIONING_INTERFACE=eth0 --env HTTP_PORT=8080 \
  -v /srv/ironic:/shared --name bmctest \
  --entrypoint sleep quay.io/metal3-io/ironic:latest infinity

sudo podman run --privileged --rm -d --net host \
  --env OS_CLOUD=bmctest --name bmcicli \
  --entrypoint sleep quay.io/metal3-io/ironic-client infinity

# Access Ironic API directly:
curl http://localhost:6385/v1

# Clean up:
sudo podman rm -f bmctest bmcicli
```

## Code Architecture

### Execution Flow

**ocpbmctest.sh** (OpenShift entry point):
1. Fetches OpenShift release image URL from mirror.openshift.com
2. Extracts Ironic container image from release
3. Parses install-config.yaml using yq to extract:
   - `provisioningBridge` (network interface)
   - BMC addresses, transforming format: `boot+protocol://address/systemid`
   - Credentials and certificate settings
4. Generates temporary YAML in upstream format
5. Invokes bmctest.sh with extracted parameters

**bmctest.sh** (core test engine):
1. Downloads CoreOS ISO from builds.coreos.fedoraproject.org (cached in /srv/ironic/html/images/)
2. Validates port availability (6385 for Ironic, configurable for HTTP/HTTPS)
3. Starts containers:
   - `bmctest`: Ironic server (privileged, --net host)
   - `bmcicli`: Ironic client with baremetal CLI
4. Starts httpd and Ironic services inside container
5. Waits for Ironic API availability (with timeout)
6. Tests each node in parallel using GNU parallel:
   - Get BMC firmware version (via Redfish API)
   - Register node and transition to managed state
   - Power on/off test
   - Set boot device to PXE
   - Deploy with virtual media (boot from ISO)
   - Eject virtual media (not supported on ilo5)
7. Aggregates results, saves logs on error or if requested
8. Cleanup trap removes containers and temp files

### Key Functions

**bmwrap()** (bmctest.sh:141-148): Wrapper for `baremetal` CLI that runs commands in bmcicli container. Uses process-specific cache directory to prevent race conditions when parallel tests access the same cache.

**test_node()** (bmctest.sh:358-399): Orchestrates all tests for a single BMC. Exported for parallel execution. Continues testing even if early tests fail (to gather maximum information).

**Parallel execution**: bmctest.sh:404-405 uses GNU parallel to test multiple BMCs concurrently. Each test gets isolated cache via bmwrap's process-specific directory.

### Supported Boot Methods

- `redfish-virtualmedia`: Generic Redfish implementation
- `idrac-virtualmedia`: Dell iDRAC with additional idrac-specific interfaces
- `ilo5-virtualmedia`: HPE iLO 5 (note: does not support eject_vmedia passthru)

Driver selection and interface mapping in test_manage() (bmctest.sh:245-287) and test_boot_vmedia() (bmctest.sh:302-333).

### Configuration Format

**OpenShift install-config.yaml:**
```yaml
platform:
  baremetal:
    provisioningBridge: eth0  # Required: network interface
    hosts:
      - name: server-name
        bmc:
          address: boot-method+protocol://ip/redfish-path
          # Example: idrac-virtualmedia+https://192.168.0.1/redfish/v1/Systems/System.Embedded.1
          username: root
          password: password
          disableCertificateVerification: true  # Optional
```

**Upstream config.yaml:**
```yaml
hosts:
  - name: server-name
    bmc:
      boot: idrac-virtualmedia       # Boot method
      protocol: https                # http or https
      address: 192.168.0.1          # BMC IP/hostname
      systemid: /redfish/v1/Systems/System.Embedded.1
      username: root
      password: password
      insecure: true                 # Equivalent to disableCertificateVerification
```

No whitespace allowed in YAML values (parsed with basic shell tools).

### Container Architecture

Both bmctest (server) and bmcicli (client) run as privileged containers with --net host to:
- Bind to network interface for provisioning
- Access ports 6385 (Ironic API) and HTTP/HTTPS ports
- Share /srv/ironic volume for ISO storage

The bmcicli container uses clouds.yaml (OS_CLOUD=bmctest) for Ironic authentication.

### Error Handling

Errors append to $ERROR_LOG (temporary file). Final exit code = line count of error log. Tests continue on failure to gather maximum diagnostic information. Logs saved automatically on any error, or with `-l always` flag.

### Network Requirements

Firewall must allow BMC → host connections:
- TCP 6385: Ironic API
- TCP 8080 (default): HTTP for virtual media
- Custom port via -T flag: HTTPS for virtual media

Dell BMCs verify HTTP accessibility before mounting ISO. HPE does not.

### Dependencies

Auto-installed via dnf on RPM distros:
- jq (JSON parsing)
- python3-pip and yq (YAML parsing, pip version not yum version)
- podman (rootless capable container runtime)
- curl (downloads, API calls)
- parallel (GNU, EPEL repo required)
- nc (netcat, port checking)

Requires: unprivileged user with passwordless sudo.

## Important Implementation Details

### Timeout Usage
The -t timeout value (default 300s) is used in 4 places per machine:
1. Node manage operation wait
2. Node power operations (per power on/off)
3. Node provide state wait
4. Node deploy state wait
5. Ironic API availability check

### Certificate Handling
When TLS_PORT is set, bmctest.sh:153-165:
- Creates self-signed certificate in container
- Sets `webserver_verify_ca = False` in ironic.conf.j2
- Enables HTTPS virtual media hosting

Per-BMC certificate verification controlled by `insecure`/`disableCertificateVerification` field, mapped to `redfish_verify_ca` driver info.

### Version Detection
get_ironic_version() (bmctest.sh:196-208) tries in order:
1. Ironic API /v1 endpoint (version.version or default_version.version)
2. Python module version inside container
3. Falls back to image name

get_bmc_firmware_version() (bmctest.sh:211-231) queries Redfish API:
1. Gets Manager link from System
2. Tries vendor-specific paths (iDRAC, iLO)
3. Falls back to common default paths
4. Returns "unknown" if all fail

### ShellCheck Configuration
.shellcheckrc disables SC2317 because parallel and trap usage creates false positives for "unreachable command" warnings.
