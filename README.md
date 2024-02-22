bmctest - test BMCs compatibility with Ironic
============================================

This tool tests Baseboard Management Controllers are manageable by Ironic

Supported opperations:
- manage (register node)
- set boot device
- boot from virtual media
- virtual media detach
- power on/off

# Description

`ocpbmctest.sh` - intermediate script that parses an `install-config.yaml` from
OpenShift install, creates an ironic image from openshift/release and calls the
actual test script.

`bmctest.sh` - runs the tests on the nodes. This script is intended to be
upstream compatible with Ironic, leaving out the OpenShift specifics.

# Requirements

Scripts need to be run as unprivileged user with passwordless sudo.

EPEL repository is required for GNU parallel.

Firewall: the servers that are tested need to be able to reach Ironic (TCP 6385)
and httpd (configurable, default TCP 8080). Note: Dell actually checks it can
mount the ISO via http, HP does not check.

Each script checks for dependencies and attempts to automatically install them
with dnf for RPM distros:
- jq
- python3-pip
- yq (the pip version)
- podman
- curl
- parallel (GNU)
- nc

# Configuration

No whitespace is allowed anywhere in the yaml config files as they are parsed
with basic shell.

Supported boot methods are:
- redfish-virtualmedia
- idrac-virtualmedia
- ilo5-virtualmedia (the driver does not support ejecting virtual media)

### For OpenShift Ironic
Example minimal `install-config.yaml` that `ocpbmctest.sh` needs:

```
platform:
  baremetal:
    provisioningBridge: eth0
    hosts:
      - name: dell-server
        bmc:
          address: idrac-virtualmedia+https://192.168.0.1/redfish/v1/Systems/System.Embedded.1
          username: root
          password: calvin
          disableCertificateVerification: true
      - name: hp-server
        bmc:
          address: redfish-virtualmedia+https://192.168.0.2/redfish/v1/Systems/1
          username: Administrator
          password: password
          disableCertificateVerification: true
```

`provisioningBridge` - the interface on the host the script is run on that ironic
and http will bind to.

### For upstream Ironic
Example minimal `config.yaml` that `bmctest.sh` needs:
(only needed for running `bmctest.sh` directly for upstream Ironic, otherwise
automatically generated from `install-config.yaml` by `ocpbmctest.sh`)

```
hosts:
    - name: dell-server
      bmc:
          boot: idrac-virtualmedia
          protocol: https
          address: 192.168.0.101
          systemid: /redfish/v1/Systems/System.Embedded.1
          username: root
          password: calvin
          insecure: true
    - name: hp-server
      bmc:
          boot: redfish-virtualmedia
          protocol: https
          address: 192.168.0.102
          systemid: /redfish/v1/Systems/1
          username: Administrator
          password: password
          insecure: true
```

`insecure` is the equivalent of `disableCertificateVerification`, meaning it
will not check the https certificate of the BMC.

