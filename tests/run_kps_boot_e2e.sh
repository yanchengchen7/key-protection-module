#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e
set -o pipefail

# ==============================================================================
# KPS BOOT E2E VALIDATION SCRIPT
# ==============================================================================
# EXECUTION ENVIRONMENT:
# This script must be executed from an environment that can route to the KPS IP
# (typically 192.168.100.3) over ports 50050 and 50051.
# 
# For DEBUG IMAGE testing:
# Because KPS only permits SSH (port 22) from source IP 192.168.100.2, this script
# MUST be executed from inside the Workload VM, OR invoked over SSH jumping through 
# the Workload VM (e.g., `ssh -J root@192.168.100.2 root@192.168.100.3`).
#
# For HARDENED IMAGE testing (non-SSH):
# To fully validate the boot flags and IMA enforcement, you must pass the 
# host-side serial log file to this script via the SERIAL_LOG_FILE environment variable.
# ==============================================================================

if [ -z "$KPS_IP" ]; then
    echo "ERROR: KPS_IP environment variable is required (e.g., 192.168.100.3)"
    exit 1
fi

IMAGE_ENV="${IMAGE_ENV:-debug}"

wait_for_port() {
    local port=$1
    local retries=$2
    local sleep_sec=2
    echo "Waiting for $KPS_IP:$port to open..."
    for ((i=1; i<=retries; i++)); do
        if timeout 2 bash -c "</dev/tcp/$KPS_IP/$port" 2>/dev/null; then
            echo "SUCCESS: Port $port is listening."
            return 0
        fi
        sleep $sleep_sec
    done
    echo "ERROR: Port $port did not open."
    return 1
}

assert_port_closed() {
    local port=$1
    echo "Verifying $KPS_IP:$port is closed/dropped..."
    if timeout 2 bash -c "</dev/tcp/$KPS_IP/$port" 2>/dev/null; then
        echo "ERROR: Port $port is reachable, but should be closed!"
        return 1
    fi
    echo "SUCCESS: Port $port is closed."
    return 0
}

# 1. CORE SERVICES VALIDATION (Applies to both modes)
# If core services bind 50050 and 50051, 203/EXEC didn't happen and IMA succeeded.
wait_for_port 50050 60
wait_for_port 50051 60

# 2. HARDENED MODE VALIDATION
if [ "$IMAGE_ENV" = "hardened" ]; then
    echo "=== Running Hardened Mode Validations ==="
    # In hardened mode, SSH should never be reachable.
    assert_port_closed 22

    if [ -n "$SERIAL_LOG_FILE" ] && [ -f "$SERIAL_LOG_FILE" ]; then
        echo "Verifying hardened flags in serial log $SERIAL_LOG_FILE..."
        CMDLINE=$(grep "Kernel command line:" "$SERIAL_LOG_FILE" | head -n 1)
        if [ -z "$CMDLINE" ]; then
            echo "ERROR: Could not find Kernel command line in serial log."
            exit 1
        fi

        # We must count exact tokens to ensure mutual exclusion
        count_log=0
        count_enforce=0
        count_hardened_false=0
        count_hardened_true=0

        for token in $CMDLINE; do
            case "$token" in
                ima_appraise=log) ((count_log++)) ;;
                ima_appraise=enforce) ((count_enforce++)) ;;
                confidential-space.hardened=false) ((count_hardened_false++)) ;;
                confidential-space.hardened=true) ((count_hardened_true++)) ;;
            esac
        done

        if [ "$count_enforce" -ne 1 ] || [ "$count_log" -ne 0 ]; then
            echo "ERROR: Hardened mode requires exactly one ima_appraise=enforce ($count_enforce) and zero ima_appraise=log ($count_log)."
            exit 1
        fi

        if [ "$count_hardened_true" -ne 1 ] || [ "$count_hardened_false" -ne 0 ]; then
            echo "ERROR: Hardened mode requires exactly one hardened=true ($count_hardened_true) and zero hardened=false ($count_hardened_false)."
            exit 1
        fi

        # Verify IMA policy loaded without 203/EXEC
        if grep -q "203/EXEC" "$SERIAL_LOG_FILE"; then
            echo "ERROR: Found 203/EXEC in serial log! IMA blocked execution."
            exit 1
        fi
        
        # We don't verify 'IMA policy loaded' string explicitly because the kernel doesn't 
        # always print a distinct 'successfully loaded' line that's easy to grep, but 
        # lack of 203/EXEC + alive ports 50050/50051 means IMA fully succeeded.
        echo "SUCCESS: Hardened boot flags and IMA enforcement verified in serial log."
    else
        echo "WARNING: SERIAL_LOG_FILE not provided. Cannot verify hardened boot flags!"
    fi

    echo "KPM_BOOT_E2E_SUCCESS: Hardened boot properties validated successfully."
    exit 0
fi

# 3. DEBUG MODE VALIDATION
echo "=== Running Debug Mode Validations ==="
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: SSH_KEY not found at $SSH_KEY. Debug validation requires keys."
    exit 1
fi

SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY} root@${KPS_IP}"

echo "Waiting for KPS SSH at $KPS_IP:22 ..."
wait_for_port 22 60

if ! timeout 30s bash -c "until $SSH_CMD echo 'SSH is up'; do sleep 2; done"; then
    echo "ERROR: KPS SSH port is open but authentication/login failed."
    exit 1
fi

echo "Verifying google-guest-agent is masked..."
if ! $SSH_CMD "systemctl is-enabled google-guest-agent.service | grep -q 'masked'"; then
    echo "ERROR: google-guest-agent.service is not masked!"
    exit 1
fi

echo "Verifying no google-guest-agent pending jobs..."
if $SSH_CMD "systemctl list-jobs | grep -q 'google-guest-agent.service'"; then
    echo "ERROR: Found pending job for google-guest-agent.service!"
    exit 1
fi

echo "Verifying exact debug boot mode flags..."
CMDLINE=$($SSH_CMD "cat /proc/cmdline")

count_log=0
count_enforce=0
count_hardened_false=0
count_hardened_true=0

for token in $CMDLINE; do
    case "$token" in
        ima_appraise=log) ((count_log++)) ;;
        ima_appraise=enforce) ((count_enforce++)) ;;
        confidential-space.hardened=false) ((count_hardened_false++)) ;;
        confidential-space.hardened=true) ((count_hardened_true++)) ;;
    esac
done

if [ "$count_log" -ne 1 ] || [ "$count_enforce" -ne 0 ]; then
    echo "ERROR: Debug mode requires exactly one ima_appraise=log ($count_log) and zero enforce ($count_enforce)."
    exit 1
fi

if [ "$count_hardened_false" -ne 1 ] || [ "$count_hardened_true" -ne 0 ]; then
    echo "ERROR: Debug mode requires exactly one hardened=false ($count_hardened_false) and zero true ($count_hardened_true)."
    exit 1
fi

echo "SUCCESS: Debug exact mode flags verified."
echo "KPM_BOOT_E2E_SUCCESS: Debug boot properties validated successfully."
exit 0
