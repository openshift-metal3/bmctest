# Integration Architecture

This document describes the improved integration between `bmctest.sh` and `ocpbmctest.sh` using a shared library approach.

## Architecture Overview

```
bmctest/
├── lib/                    # Shared libraries
│   ├── common.sh           # Common utilities (validation, logging, etc.)
│   └── config.sh           # Config parsing and transformation
├── bmctest.sh              # Upstream Ironic test entry point
├── ocpbmctest.sh           # OpenShift test entry point (wrapper)
└── clouds.yaml             # Ironic API credentials
```

## Shared Libraries

### lib/common.sh

Provides common utilities used by both scripts:

- **`timestamp()`** - Timestamped logging
- **`check_sudo()`** - Validate passwordless sudo access
- **`ensure_dependencies()`** - Install missing system dependencies
- **`validate_config_file()`** - Check if config file exists
- **`validate_file_exists()`** - Generic file existence check
- **`check_port_available()`** - Verify TCP port is not in use
- **`validate_ocp_config()`** - Validate OpenShift install-config.yaml structure
- **`validate_upstream_config()`** - Validate upstream config.yaml structure
- **`debug_log()`** - Debug logging when `BMCTEST_DEBUG=1`

### lib/config.sh

Provides configuration parsing and transformation:

- **`transform_ocp_to_upstream()`** - Convert OpenShift format to upstream format
- **`get_ocp_interface()`** - Extract provisioning interface from OpenShift config
- **`count_hosts()`** - Count hosts in either config format
- **`validate_bmc_address()`** - Validate BMC address format

## Integration Flow

### OpenShift Workflow (ocpbmctest.sh)

```
1. Parse command-line arguments
2. Validate OpenShift install-config.yaml exists and structure is correct
3. Fetch OpenShift release image URL
4. Extract Ironic container image from release
5. Extract provisioning interface using get_ocp_interface()
6. Transform config to upstream format using transform_ocp_to_upstream()
7. Validate transformed config using validate_upstream_config()
8. Call bmctest.sh with extracted parameters
```

### Upstream Workflow (bmctest.sh)

```
1. Parse command-line arguments
2. Validate upstream config.yaml exists and structure is correct
3. Check dependencies and ports
4. Download CoreOS ISO (if needed)
5. Start Ironic containers
6. Test each BMC in parallel
7. Report results and save logs
```

## Usage Examples

### Basic Usage

```bash
# OpenShift workflow
./ocpbmctest.sh -c install-config.yaml

# Upstream workflow
./bmctest.sh -I eth0 -c config.yaml
```

### With Debug Mode

```bash
# See transformation details
BMCTEST_DEBUG=1 ./ocpbmctest.sh -c install-config.yaml

# Debug upstream validation
BMCTEST_DEBUG=1 ./bmctest.sh -I eth0 -c config.yaml
```

### Using Library Functions Directly

```bash
# Source the libraries
source lib/common.sh
source lib/config.sh

# Use functions
validate_ocp_config "install-config.yaml"
transform_ocp_to_upstream "install-config.yaml" "output.yaml"
validate_upstream_config "output.yaml"
```

## Error Messages

The integration provides clear, actionable error messages:

### Config Validation Errors

```
ERROR: config missing platform.baremetal section
ERROR: config missing provisioningBridge or externalBridge
ERROR: config has no hosts defined
ERROR: hosts missing required BMC fields: server1, server2
```

### File Validation Errors

```
ERROR: config file "install-config.yaml" does not exist
ERROR: pull secret file "/path/to/secret" does not exist
```

### Port Availability Errors

```
ERROR: Ironic port 6385 already in use
ERROR: HTTP port 8080 already in use
ERROR: HTTPS port 8443 already in use
```

### Transformation Errors

```
ERROR: Failed to transform config
ERROR: Config transformation failed validation
```

## Testing

Run shellcheck on all files:
```bash
shellcheck bmctest.sh ocpbmctest.sh lib/*.sh
```

Test with sample configs:
```bash
# Create test config
cat > test-config.yaml <<EOF
hosts:
  - name: test-server
    bmc:
      boot: redfish-virtualmedia
      protocol: https
      address: 192.168.1.100
      systemid: /redfish/v1/Systems/1
      username: admin
      password: password
      insecure: true
EOF

# Validate
source lib/common.sh
source lib/config.sh
validate_upstream_config test-config.yaml
```

## Support

For issues or questions:
1. Check error messages - they provide specific guidance
2. Enable debug mode with `BMCTEST_DEBUG=1`
3. Review validation output for configuration issues
4. Check shellcheck output for syntax issues
