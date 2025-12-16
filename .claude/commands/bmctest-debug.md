# BMC Test Debug Workflow

You are helping the user run bmctest and analyze the results. Follow this workflow:

## Step 1: Determine Test Type and Configuration

First, check if the user provided arguments with the command (e.g., `/bmctest-debug upstream demo.yaml`).

If arguments were provided:
- Parse the first argument as the test type (upstream or openshift)
- Parse the second argument as the config file path

If no arguments were provided, ask the user:
1. Which workflow to use:
   - `upstream`: Run bmctest.sh (requires -I interface flag)
   - `openshift`: Run ocpbmctest.sh (uses install-config.yaml format)

2. Which YAML config file to use (offer to list available .yaml files in the current directory)

## Step 2: Check Available Network Interfaces

Run `ip addr show | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':'` to show available network interfaces.

For upstream workflow, ask which interface to use (or default to the first non-loopback interface).

## Step 3: Offer Configuration Options

Ask the user if they want to:
- Run with default settings
- Customize options

If customizing, present these common options:
- `-r VERSION`: OpenShift release version (openshift only, default: 4.18)
- `-p PORT`: HTTP port for virtual media (default: 8080)
- `-T PORT`: Enable HTTPS virtual media on specified port
- `-t TIMEOUT`: Timeout in seconds (default: 300)
- `-l always`: Save Ironic log even on success (default: on_error)
- `-i IMAGE`: Custom ironic image (upstream only)

## Step 4: Run the Test

Build and execute the appropriate command:

**For upstream:**
```bash
./bmctest.sh -I <interface> -c <config.yaml> [additional options]
```

**For openshift:**
```bash
./ocpbmctest.sh -c <install-config.yaml> [additional options]
```

Run the command with a long timeout (e.g., 600000ms) to allow the test to complete.

## Step 5: Parse and Summarize Results

After the test completes, analyze the output:

1. Extract the exit code (number of errors)
2. Parse the output for each BMC tested:
   - BMC name
   - Firmware version
   - Test results for each phase:
     - Firmware version detection
     - Node management
     - Power on/off
     - Boot device setting
     - Virtual media boot
     - Media eject
3. Note which tests passed (✓) and which failed (✗)
4. Identify the Ironic version used

Present a summary in this format:

```
### Test Results Summary

Exit Code: X (X errors)
Ironic Version: X.XX

**BMC: <name> (<vendor> <model> <firmware>)**
- ✓/✗ Firmware detection
- ✓/✗ Node management
- ✓/✗ Power on/off
- ✓/✗ Boot device (PXE)
- ✓/✗ Virtual media boot
- ✓/✗ Media eject

[Repeat for each BMC]
```

## Step 6: Root Cause Analysis (If Errors Present)

If the exit code is non-zero or any tests failed:

1. Identify the most recent ironic log file:
   ```bash
   ls -t ironic_*.log | head -1
   ```

2. For each failed BMC/test, investigate the log:
   - Search for the BMC's node UUID or name
   - Look for error messages, timeouts, HTTP status codes
   - Check for lock contentions (HTTP 409)
   - Examine power state transitions
   - Review Redfish API interactions (sushy.connector logs)
   - Look for timing issues or async operation failures

3. Provide a detailed root cause analysis including:
   - **What failed:** Specific test(s) and BMC(s)
   - **When it failed:** Timeline of events from the log
   - **Why it failed:** Root cause (e.g., BMC bug, timeout, incompatibility)
   - **Evidence:** Relevant log excerpts with timestamps
   - **Recommendation:** Potential fixes or workarounds

Example format:

```
### Root Cause Analysis

**BMC: <name>**

**Failures:**
- Boot device setting
- Virtual media boot
- Media eject

**Timeline:**
1. HH:MM:SS - Power-off requested
2. HH:MM:SS - BMC returned HTTP 202 (Accepted)
3. HH:MM:SS - Node remained in "power on" state
4. HH:MM:SS - Ironic held exclusive lock waiting for state change
5. HH:MM:SS - Subsequent operations failed with HTTP 409 (locked)

**Root Cause:**
The BMC's Redfish implementation has a bug in async power state handling.
When ForceOff is requested, it returns HTTP 202 but never actually changes
the power state, causing Ironic to wait indefinitely while holding an
exclusive lock that blocks all other operations.

**Evidence:**
```
[timestamp] INFO Node <uuid> current power state is 'power on', requested state is 'power off'
[timestamp] HTTP response POST .../Reset: status code: 202
[timestamp] Client-side error: Node <uuid> is locked by host...
```

**Recommendation:**
This appears to be a firmware bug in the BMC. Consider:
1. Updating BMC firmware to latest version
2. Using a different boot method if available
3. Increasing timeout value with -t flag
4. Reporting to BMC vendor with logs
```

## Step 7: Offer Next Steps

After analysis, ask the user if they want to:
- Re-run the test with different options
- Examine specific parts of the log in detail
- Generate a bug report
- Test a specific BMC individually
- Clean up log files

## Important Notes

- Always use the Read tool to view log files
- Use grep/bash commands efficiently to search large log files
- When searching logs, look for node UUIDs as well as node names
- Pay attention to request IDs to trace operations across log entries
- Note that errors may be logged before the final summary output
- The exit code equals the number of errors encountered
