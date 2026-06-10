#!/usr/bin/env bash
# End-to-end harness for manager.sh. Every Proxmox / hardware touchpoint (qm,
# lscpu, lspci, systemctl, nvidia-smi, /proc/irq, /sys) is faked via PATH stubs
# and the script's *_BASE/_FILE override variables, so the full pipeline runs
# in any container. Each scenario gets a scratch cwd; assertions grep the
# combined stdout+stderr log and the artifacts (state file, call logs, fake
# /etc trees) the run leaves behind.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
MANAGER="$ROOT/manager.sh"
STUBS="$HERE/stubs"
FIXTURES="$HERE/fixtures"

PASS=0
FAIL=0
CURRENT_SCENARIO=""

fail() {
    FAIL=$((FAIL + 1))
    echo "    FAIL: $1"
}

ok() {
    PASS=$((PASS + 1))
    echo "    ok:   $1"
}

# assert_grep <file> <ERE> <description>
assert_grep() {
    if grep -qE "$2" "$1" 2>/dev/null; then ok "$3"; else
        fail "$3 (pattern not found: $2 in $1)"
        sed 's/^/      | /' "$1" 2>/dev/null | tail -40
    fi
}

# assert_not_grep <file> <ERE> <description>
assert_not_grep() {
    if grep -qE "$2" "$1" 2>/dev/null; then
        fail "$3 (unexpected pattern: $2 in $1)"
        grep -nE "$2" "$1" | sed 's/^/      | /'
    else ok "$3"; fi
}

assert_exit_code() {
    if [[ "$1" -eq "$2" ]]; then ok "$3"; else fail "$3 (expected exit $1, got $2)"; fi
}

assert_file_exists() {
    if [[ -e "$1" ]]; then ok "$2"; else fail "$2 (missing: $1)"; fi
}

assert_file_absent() {
    if [[ ! -e "$1" ]]; then ok "$2"; else fail "$2 (unexpectedly exists: $1)"; fi
}

# assert_json <file> <jq-expr> <description>: jq expression must output "true"
assert_json() {
    local got
    got=$(jq -r "$2" "$1" 2>/dev/null)
    if [[ "$got" == "true" ]]; then ok "$3"; else fail "$3 (jq '$2' -> '$got')"; fi
}

scenario() {
    CURRENT_SCENARIO="$1"
    echo ""
    echo "=== scenario: $1 ==="
    WORK=$(mktemp -d)
    cd "$WORK"
    # Reset per-scenario stub knobs to a clean default.
    export PATH="$STUBS:$PATH"
    export LSCPU_TOPOLOGY="$FIXTURES/topology-intel-2s.csv"
    export QM_FIXTURE_DIR="$FIXTURES/qm-basic"
    export QM_CALL_LOG="$WORK/qm-calls.log"
    export SYSTEMCTL_CALL_LOG="$WORK/systemctl-calls.log"
    export IRQ_PROC_BASE="$WORK/fake-irq"
    unset LSPCI_FIXTURE NVIDIA_SMI_MEM_MB 2>/dev/null || true
    mkdir -p "$IRQ_PROC_BASE"
}

# make_irq <number> <device-name> <affinity-list> [effective-list]
make_irq() {
    local d="$IRQ_PROC_BASE/$1"
    mkdir -p "$d/$2"
    echo "$3" > "$d/smp_affinity_list"
    if [[ -n "${4:-}" ]]; then echo "$4" > "$d/effective_affinity_list"; fi
}

write_basic_config() {
    cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": {
    "cpu_config_string": "host",
    "reserve_host_cores": true,
    "host_cores": [0, 8],
    "parallel_jobs": 2,
    "state_file": "manager_state.json"
  },
  "gpu_settings": {
    "required_vram_mb": 2048,
    "auto_detect_profile": false,
    "gpu_profile_map": { "0000:04:00.0": "nvidia-47" }
  },
  "disk_settings": {
    "storage_node_map": { "local-lvm": "node:0" }
  },
  "vms": { "101": 2, "102": 2, "103": 2, "104": 2 }
}
EOF
}

run_manager() {
    local rc=0
    "$MANAGER" "$@" > "$WORK/run.log" 2>&1 || rc=$?
    RUN_RC=$rc
    return 0
}

# =============================================================================
scenario "cpu-only dry-run plans NUMA + disk-locality layout"
write_basic_config
run_manager -f "$WORK/config.json" -n -g

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "Planning Complete" "planning completes"
assert_grep "$WORK/run.log" "Script finished" "execution phase finishes"
# Disk locality: all four VMs prefer node 0 via storage map; first three fit,
# the fourth (VM 101, smallest sort key last) overflows to node 1.
assert_grep "$WORK/run.log" "Assigning VM 104 to Node 0 \(disk prefers Node 0" "VM 104 lands on its disk node"
assert_grep "$WORK/run.log" "Assigning VM 101 to Node 1" "VM 101 overflows to node 1"
# Host cores 0+8 are excluded from every affinity assignment.
assert_not_grep "$WORK/run.log" "Set Affinity: (0|8)[, ]" "reserved host cores never assigned to VMs"
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 1,9 \(Node 0\)" "VM gets paired phys+SMT cores on node 0"
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 4,12 \(Node 1\)" "overflow VM gets cores on node 1"
# Dry run must not invoke qm set or systemctl mutations.
assert_not_grep "$WORK/qm-calls.log" "^qm set" "dry run never calls qm set"
assert_not_grep "$WORK/systemctl-calls.log" "set-property" "dry run never calls systemctl set-property"

STATE_FILE_PATH="$WORK/manager_state.json"
assert_file_exists "$STATE_FILE_PATH" "state file written"
assert_json "$STATE_FILE_PATH" '.core_assignments | length == 4' "state file covers all 4 VMs"
assert_json "$STATE_FILE_PATH" '.core_assignments["101"].numa_node == 1' "state file records VM 101 on node 1"

# =============================================================================
scenario "gpu-mode dry-run degrades to cpu-only when GPU has no mdev support"
write_basic_config
export LSPCI_FIXTURE="$FIXTURES/lspci-one-gpu.txt"
run_manager -f "$WORK/config.json" -n

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "GPU 0000:04:00.0: No MDEV support found" "GPU without mdev is reported"
assert_grep "$WORK/run.log" "0 VM\(s\) with GPU, 4 VM\(s\) CPU-only" "all VMs fall back to CPU-only"
assert_grep "$WORK/run.log" "Planning Complete" "planning completes"
assert_exit_code 0 "$RUN_RC" "best-effort fallback is not fatal"

# =============================================================================
scenario "reset mode prints undo commands without touching anything"
write_basic_config
run_manager -f "$WORK/config.json" -r

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "systemctl set-property system.slice AllowedCPUs" "prints slice reset"
assert_not_grep "$WORK/qm-calls.log" "^qm" "reset mode never calls qm"

# =============================================================================
echo ""
echo "================================================="
echo "  $PASS passed, $FAIL failed"
echo "================================================="
[[ $FAIL -eq 0 ]]
