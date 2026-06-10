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
    unset LSPCI_FIXTURE NVIDIA_SMI_MEM_MB QM_FAIL_SET_VMIDS SYSTEMCTL_IS_ENABLED_RC \
        QEMU_PID_DIR PROC_BASE TASKSET_CALL_LOG 2>/dev/null || true
    mkdir -p "$IRQ_PROC_BASE"
    # Hermetic-by-default host touchpoints: every override the manager honors
    # points at a fresh fake under $WORK, so nothing a scenario does (or
    # forgets to do) can read or touch the real host. Previously several of
    # these were merely unset and fell back to the real paths -- scenarios
    # that relied on "no mdev support" or "no hugepage pool" passed in CI
    # containers but failed on actual vGPU hosts, every scenario flocked the
    # REAL /run/lock/affinity-manager.lock (colliding with production runs),
    # and dry-run logs quoted the real /etc/default/grub.
    export PCI_SYS_BASE="$WORK/fake-pci"          # make_gpu populates
    export NODE_SYS_BASE="$WORK/fake-node"        # make_node_hugepages populates
    mkdir -p "$PCI_SYS_BASE" "$NODE_SYS_BASE"
    export LOCK_FILE="$WORK/lock"
    export GRUB_FILE="$WORK/fake-grub"
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
    export SYSTEMD_ETC="$WORK/fake-systemd-etc"
    export PROC_SYS_BASE="$WORK/fake-procsys"
    export SYSCTL_D="$WORK/fake-sysctld"
    export KSM_RUN_FILE="$WORK/fake-ksm-run"
    export CPUFREQ_BASE="$WORK/fake-cpufreq"
    export PROC_CMDLINE_FILE="$WORK/fake-cmdline"
    printf 'BOOT_IMAGE=/boot/vmlinuz quiet\n' > "$PROC_CMDLINE_FILE"
    # Keep the hookscript's append-log off unless a scenario opts in.
    export VCPU_PIN_LOG=""
}

# make_gpu <pci> <numa-node> <profile> <available-instances>: fake PCI sysfs
make_gpu() {
    local d="$WORK/fake-pci/$1"
    mkdir -p "$d/mdev_supported_types/$3"
    echo "$2" > "$d/numa_node"
    echo "$4" > "$d/mdev_supported_types/$3/available_instances"
    echo "num_heads=4, frl_config=60, framebuffer=2048M, max_resolution=5120x2880" \
        > "$d/mdev_supported_types/$3/description"
    export PCI_SYS_BASE="$WORK/fake-pci"
}

# make_node_hugepages <node> <nr_1g_pages> [free_pages]: fake NUMA-node hugepage sysfs
make_node_hugepages() {
    local d="$WORK/fake-node/node$1/hugepages/hugepages-1048576kB"
    mkdir -p "$d"
    echo "$2" > "$d/nr_hugepages"
    echo "${3:-$2}" > "$d/free_hugepages"
    export NODE_SYS_BASE="$WORK/fake-node"
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
# Host pinning plan: qemu.slice AllowedCPUs (machine.slice CPUAffinity was inert).
assert_grep "$WORK/run.log" "qemu\.slice\.d/99-vm-cores\.conf" "dry run plans qemu.slice drop-in"
assert_grep "$WORK/run.log" "AllowedCPUs=1-7,9-15" "dry run plans AllowedCPUs ranges for VM cores"
assert_not_grep "$WORK/run.log" "machine\.slice" "machine.slice no longer referenced"

# Dry run writes its state beside the configured state file, never over it.
STATE_FILE_PATH="$WORK/manager_state.json.dryrun"
assert_file_exists "$STATE_FILE_PATH" "dry-run state file written to .dryrun"
assert_file_absent "$WORK/manager_state.json" "real state file untouched by dry run"
assert_json "$STATE_FILE_PATH" '.core_assignments | length == 4' "state file covers all 4 VMs"
assert_json "$STATE_FILE_PATH" '.core_assignments["101"].numa_node == 1' "state file records VM 101 on node 1"
assert_json "$STATE_FILE_PATH" '.metadata.applied == false' "dry-run state is marked applied=false"
# Post-run checks run in dry-run mode too, and say why GRUB is not in sync.
assert_grep "$WORK/run.log" "does not contain the planned isolation params \(dry run did not write them\)" "dry run explains unwritten GRUB params"

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
assert_grep "$WORK/run.log" "qemu\.slice\.d/99-vm-cores\.conf" "reset covers qemu.slice drop-in"
assert_not_grep "$WORK/qm-calls.log" "^qm" "reset mode never calls qm"

# =============================================================================
scenario "gpu-mode survives a host with zero NVIDIA devices"
write_basic_config
# No LSPCI_FIXTURE: lspci emits nothing. The lspci|grep pipeline used to kill
# the script under set -e with no error message at all.
run_manager -f "$WORK/config.json" -n

assert_exit_code 0 "$RUN_RC" "exits 0 instead of dying silently"
assert_grep "$WORK/run.log" "No NVIDIA display-class devices found" "warns about missing GPUs"
assert_grep "$WORK/run.log" "Planning Complete" "planning still completes"

# =============================================================================
scenario "full apply writes qemu.slice drop-in, GRUB params, IRQ masks, qm config"
cat > "$WORK/config.json" <<EOF
{
  "global_settings": {
    "cpu_config_string": "host",
    "reserve_host_cores": true,
    "host_cores": [0, 8],
    "parallel_jobs": 2,
    "state_file": "$WORK/state.json"
  },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 2, "102": 2, "103": 2, "104": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
export GRUB_FILE="$WORK/grub"
export SYSTEMD_ETC="$WORK/sysd"
printf 'GRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
# Legacy drop-in from older versions must be cleaned up.
mkdir -p "$SYSTEMD_ETC/system/machine.slice.d"
printf '[Slice]\nCPUAffinity=1 2 3\n' > "$SYSTEMD_ETC/system/machine.slice.d/99-vm-cores.conf"
make_node_hugepages 0 8
make_node_hugepages 1 8
make_irq 30 eth0 "0-15"
make_irq 31 nvme0q1 "0,8"
run_manager -f "$WORK/config.json" -g

assert_exit_code 0 "$RUN_RC" "apply exits 0"
assert_grep "$SYSTEMD_ETC/system/qemu.slice.d/99-vm-cores.conf" "^AllowedCPUs=1-7,9-15$" "qemu.slice drop-in uses AllowedCPUs"
assert_file_absent "$SYSTEMD_ETC/system/machine.slice.d/99-vm-cores.conf" "obsolete machine.slice drop-in removed"
assert_grep "$SYSTEMD_ETC/system.conf.d/99-host-cores.conf" "^CPUAffinity=0 8$" "PID1 CPUAffinity drop-in written"
assert_grep "$WORK/grub" '^GRUB_CMDLINE_LINUX_DEFAULT="quiet isolcpus=managed_irq,domain,1-7,9-15 nohz_full=1-7,9-15 rcu_nocbs=1-7,9-15"$' "GRUB params appended inside existing double quotes"
assert_grep "$IRQ_PROC_BASE/30/smp_affinity_list" "^0,8$" "overlapping device IRQ steered to host cores"
assert_grep "$IRQ_PROC_BASE/31/smp_affinity_list" "^0,8$" "already-confined IRQ left as-is"
assert_grep "$WORK/run.log" "IRQ confinement: 1 moved, 1 already on host cores" "IRQ summary correct"
assert_grep "$WORK/systemctl-calls.log" "^systemctl set-property system.slice AllowedCPUs=0 8$" "host slice cpuset applied"
assert_grep "$WORK/systemctl-calls.log" "^systemctl daemon-reexec$" "systemd reloaded"
# Per-VM qm configuration (VM 104 planned first: cores 1,9 on node 0).
assert_grep "$WORK/qm-calls.log" "^qm set 104 -cores 2 -cpu host -affinity 1,9$" "VM 104 affinity applied"
assert_grep "$WORK/qm-calls.log" "^qm set 104 -numa 1 -numa0 cpus=0-1,hostnodes=0,memory=2048,policy=bind -hugepages 1024 -balloon 0$" "VM 104 NUMA binding applied"
assert_grep "$WORK/qm-calls.log" "^qm set 101 -cores 2 -cpu host -affinity 4,12$" "VM 101 overflows to node 1 cores"
assert_grep "$WORK/qm-calls.log" "^qm set 104 -net0 virtio=AA:BB:CC:DD:EE:04,bridge=vmbr0,queues=2$" "virtio multiqueue set to vCPU count"
assert_grep "$WORK/qm-calls.log" "^qm set 104 -scsi0 local-lvm:vm-104-disk-0,size=32G,iothread=1$" "iothread enabled on boot disk"
assert_file_exists "$WORK/state.json" "state written to configured state_file path"
assert_json "$WORK/state.json" '.core_assignments | length == 4' "state covers all VMs"
assert_json "$WORK/state.json" '.metadata.applied == true' "state is marked applied after a successful apply"
# Post-run checks: GRUB was just updated but the (fake) booted cmdline has no
# isolation params; the IRQ unit is not enabled; no VM has a hookscript.
assert_grep "$WORK/run.log" "POST-RUN CHECKS" "post-run summary printed"
assert_grep "$WORK/run.log" "REBOOT REQUIRED: the booted kernel does not match the GRUB isolation params" "reboot requirement flagged"
assert_grep "$WORK/run.log" "affinity-manager-irq.service is NOT enabled" "missing IRQ boot unit flagged"
assert_grep "$WORK/run.log" "4 VM\(s\) have NO hookscript attached: 101 102 103 104" "missing hookscripts flagged with VMIDs"

# =============================================================================
scenario "post-run checks pass when GRUB matches boot, IRQ unit enabled, hook attached"
write_basic_config
# host_cores [0,8] on the intel-2s topology -> VM cores 1-7,9-15.
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet isolcpus=managed_irq,domain,1-7,9-15 nohz_full=1-7,9-15 rcu_nocbs=1-7,9-15"\n' > "$GRUB_FILE"
printf 'BOOT_IMAGE=/boot/vmlinuz quiet isolcpus=managed_irq,domain,1-7,9-15 nohz_full=1-7,9-15 rcu_nocbs=1-7,9-15\n' > "$PROC_CMDLINE_FILE"
export SYSTEMCTL_IS_ENABLED_RC=0
run_manager -f "$WORK/config.json" -n -g -s "local:snippets/vcpu-pin-hook.sh"

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "GRUB: isolation params match the booted kernel -- no reboot needed" "no-reboot case detected"
assert_grep "$WORK/run.log" "affinity-manager-irq.service is enabled" "enabled IRQ unit detected"
assert_grep "$WORK/run.log" "would be attached to all 4 VM\(s\)" "hookscript coverage via -s acknowledged"
assert_grep "$WORK/run.log" "All post-run checks passed" "green summary verdict"

# Same, but the hookscript is already present in each VM's config (no -s).
mkdir -p "$WORK/qm-hooked"
for v in 101 102 103 104; do
    cp "$FIXTURES/qm-basic/$v.conf" "$WORK/qm-hooked/$v.conf"
    echo "hookscript: local:snippets/vcpu-pin-hook.sh" >> "$WORK/qm-hooked/$v.conf"
done
export QM_FIXTURE_DIR="$WORK/qm-hooked"
run_manager -f "$WORK/config.json" -n -g
assert_grep "$WORK/run.log" "all 4 VM\(s\) have a hookscript attached" "hookscript detected from VM configs"

# =============================================================================
scenario "a failed qm set leaves the state file marked applied=false"
cat > "$WORK/config.json" <<EOF
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8], "state_file": "$WORK/state.json" },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 2, "102": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
export QM_FAIL_SET_VMIDS="102"
run_manager -f "$WORK/config.json" -g

assert_exit_code 1 "$RUN_RC" "apply exits non-zero"
assert_grep "$WORK/run.log" "Configuration failed for VM\(s\): 102" "failed VM reported"
assert_file_exists "$WORK/state.json" "state file records the attempted plan"
assert_json "$WORK/state.json" '.metadata.applied == false' "state stays applied=false after a failed apply"
assert_json "$WORK/state.json" '.core_assignments | length == 2' "attempted plan covers both VMs"

# =============================================================================
scenario "apply preserves single-quoted GRUB_CMDLINE_LINUX_DEFAULT"
cat > "$WORK/config.json" <<EOF
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8], "state_file": "$WORK/state.json" },
  "vms": { "101": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
export GRUB_FILE="$WORK/grub"
export SYSTEMD_ETC="$WORK/sysd"
printf "GRUB_CMDLINE_LINUX_DEFAULT='quiet splash'\n" > "$GRUB_FILE"
run_manager -f "$WORK/config.json" -g

assert_exit_code 0 "$RUN_RC" "apply exits 0"
assert_grep "$WORK/grub" "^GRUB_CMDLINE_LINUX_DEFAULT='quiet splash isolcpus=managed_irq,domain,1-7,9-15 nohz_full=1-7,9-15 rcu_nocbs=1-7,9-15'$" "params appended inside single quotes, no stray double quote"

# =============================================================================
scenario "reserving every CPU fails the plan cleanly, not with a crash"
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": {
    "reserve_host_cores": true,
    "host_cores": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]
  },
  "vms": { "101": 2 }
}
EOF
export SYSTEMD_ETC="$WORK/sysd"
run_manager -f "$WORK/config.json" -n -g

assert_exit_code 1 "$RUN_RC" "exits 1"
assert_grep "$WORK/run.log" "no NUMA node has enough free cores" "planner reports the real problem"
assert_not_grep "$WORK/run.log" "unbound variable" "no bash crash"
assert_file_absent "$WORK/sysd" "host pinning never applied when the plan fails"

# =============================================================================
scenario "gpu pairing assigns NUMA-local slots with disk-locality preference"
write_basic_config
# Add the second GPU to the profile map.
jq '.gpu_settings.gpu_profile_map["0000:84:00.0"] = "nvidia-47"' "$WORK/config.json" > "$WORK/config.json.tmp"
mv "$WORK/config.json.tmp" "$WORK/config.json"
export LSPCI_FIXTURE="$FIXTURES/lspci-two-gpus.txt"
make_gpu 0000:04:00.0 0 nvidia-47 2
make_gpu 0000:84:00.0 1 nvidia-47 2
run_manager -f "$WORK/config.json" -n

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "Registered GPU 0000:04:00.0: Profile nvidia-47 \| Slots Available: 2 \| Node: 0" "GPU on node 0 registered"
assert_grep "$WORK/run.log" "Registered GPU 0000:84:00.0: Profile nvidia-47 \| Slots Available: 2 \| Node: 1" "GPU on node 1 registered"
assert_grep "$WORK/run.log" "Assigning GPU 0000:04:00.0 \(nvidia-47\) on Node 0 to VM 104 \(disk prefers Node 0.*matched=yes" "first VM pairs with disk-local GPU"
assert_grep "$WORK/run.log" "Assigning GPU 0000:84:00.0 \(nvidia-47\) on Node 1 to VM 102" "third VM spills to node-1 GPU when node-0 slots exhaust"
assert_grep "$WORK/run.log" "4 VM\(s\) with GPU, 0 VM\(s\) CPU-only" "all VMs got a GPU"
assert_grep "$WORK/run.log" "\[DRY RUN\] Set GPU: 0000:84:00.0 \(nvidia-47\)" "GPU attach planned"

# =============================================================================
scenario "-a least-GPU-loaded node selection works with auto-detected GPUs"
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [] },
  "gpu_settings": { "required_vram_mb": 2048, "auto_detect_profile": true },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 2, "102": 2, "103": 2, "104": 2 }
}
EOF
export LSPCI_FIXTURE="$FIXTURES/lspci-two-gpus.txt"
# Node 0 GPU has free slots, node 1 GPU has none -> node 1 is least loaded.
make_gpu 0000:04:00.0 0 nvidia-47 2
make_gpu 0000:84:00.0 1 nvidia-47 0
run_manager -f "$WORK/config.json" -n -a 1

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "Least GPU-loaded NUMA node: Node 1" "auto-detected GPUs drive node selection (was: always node 0)"
assert_grep "$WORK/run.log" "DRY RUN: Would update host_cores" "dry run does not rewrite config"
assert_grep "$WORK/run.log" "Planning Complete" "planning completes"

# =============================================================================
scenario "a typo'd VMID aborts the run before ANY host or VM mutation"
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8] },
  "vms": { "101": 2, "999": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
export GRUB_FILE="$WORK/grub"
export SYSTEMD_ETC="$WORK/sysd"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
run_manager -f "$WORK/config.json" -g

assert_exit_code 1 "$RUN_RC" "exits 1"
assert_grep "$WORK/run.log" "VM\(s\) not found on this node: 999\. No changes were applied\." "missing VM reported"
assert_file_absent "$WORK/sysd" "no systemd drop-ins written"
assert_grep "$WORK/grub" '^GRUB_CMDLINE_LINUX_DEFAULT="quiet"$' "GRUB untouched"
assert_not_grep "$WORK/qm-calls.log" "^qm set" "no VM was reconfigured"
assert_not_grep "$WORK/systemctl-calls.log" "set-property" "no slice was touched"

# =============================================================================
scenario "invalid core counts and host_cores are rejected up front"
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": false },
  "vms": { "101": 0 }
}
EOF
run_manager -f "$WORK/config.json" -n -g
assert_exit_code 1 "$RUN_RC" "core count 0 exits 1"
assert_grep "$WORK/run.log" "VM 101: invalid core count '0'" "core count validated"

cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 99] },
  "vms": { "101": 2 }
}
EOF
run_manager -f "$WORK/config.json" -n -g
assert_exit_code 1 "$RUN_RC" "foreign host core exits 1"
assert_grep "$WORK/run.log" "host_cores entry '99' is not a CPU on this host" "host_cores validated against topology"

# =============================================================================
scenario "concurrent runs are blocked by the lock"
write_basic_config
export LOCK_FILE="$WORK/lock"
exec 8>"$LOCK_FILE"
flock -n 8
run_manager -f "$WORK/config.json" -n -g
exec 8>&-

assert_exit_code 1 "$RUN_RC" "second instance exits 1"
assert_grep "$WORK/run.log" "Another instance is already running" "lock contention reported"

# =============================================================================
scenario "pending changes on running VMs are surfaced with a restart hint"
mkdir -p "$WORK/qm"
cp "$FIXTURES/qm-mem/"*.conf "$WORK/qm/"
echo "status: running" > "$WORK/qm/104.status"
printf 'cur cores 2\npending affinity 1,9\npending numa0 cpus=0-1,hostnodes=0,memory=2048,policy=bind\n' > "$WORK/qm/104.pending"
cat > "$WORK/config.json" <<EOF
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8], "state_file": "$WORK/state.json" },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 2, "102": 2, "103": 2, "104": 2 }
}
EOF
export QM_FIXTURE_DIR="$WORK/qm"
export GRUB_FILE="$WORK/grub"
export SYSTEMD_ETC="$WORK/sysd"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
make_node_hugepages 0 8
make_node_hugepages 1 8
run_manager -f "$WORK/config.json" -g

assert_exit_code 0 "$RUN_RC" "apply exits 0"
assert_grep "$WORK/run.log" "VM 104 is running: 2 change\(s\) are PENDING" "per-VM pending warning"
assert_grep "$WORK/run.log" "PENDING CHANGES: VM\(s\) 104 are running and must be power-cycled" "end-of-run restart summary"

# =============================================================================
scenario "planner warns when 1G hugepages are planned but not free or not configured"
write_basic_config
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
# Node 0 has 8 pages allocated but only 1 actually free.
make_node_hugepages 0 8 1
make_node_hugepages 1 8 8
run_manager -f "$WORK/config.json" -n -g
assert_exit_code 0 "$RUN_RC" "plan still succeeds"
assert_grep "$WORK/run.log" "Node 0: plan needs 6x1G hugepages but only 1 are free" "free-pool shortfall warned"

# Same plan against a host with no 1G hugepage pool at all (sysfs absent).
export NODE_SYS_BASE="$WORK/empty-node-tree"
mkdir -p "$NODE_SYS_BASE"
run_manager -f "$WORK/config.json" -n -g
assert_exit_code 0 "$RUN_RC" "plan still succeeds without a hugepage pool"
assert_grep "$WORK/run.log" "1G hugepages planned, but this node exposes no 1G hugepage pool" "missing hugepage pool warned"

# =============================================================================
scenario "SMT siblings stay inside one VM even with mixed core counts"
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8] },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 4, "102": 3, "103": 3 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-basic"
run_manager -f "$WORK/config.json" -n -g

assert_exit_code 0 "$RUN_RC" "exits 0"
# VM 101 (4 cores, node 0): phys 1,2 + their own siblings 9,10.
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 1,2,9,10 \(Node 0\)" "VM 101 pairs phys with own siblings"
# VM 103 (3 cores, node 1): phys 4,5 + sibling 12 (a sibling of core 4).
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 4,5,12 \(Node 1\)" "VM 103 pairs phys with own sibling"
# VM 102 (3 cores, node 1): phys 6,7 + sibling 14. The old allocator took the
# SMT list head: 13 -- the sibling of VM 103's core 5, i.e. cross-VM sharing
# of one physical core's pipeline.
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 6,7,14 \(Node 1\)" "VM 102 avoids VM 103's sibling thread"

# =============================================================================
scenario "AMD-style interleaved sibling enumeration is classified correctly"
export LSCPU_TOPOLOGY="$FIXTURES/topology-amd-interleaved.csv"
# Siblings are ADJACENT here (cpu0+1 = core 0, ...). The old range-based split
# (ids 0..7 physical, 8..15 SMT) would call four SMT threads "physical" and
# reserve the wrong host cores.
cat > "$WORK/config.json" <<'EOF'
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 1] },
  "disk_settings": { "storage_node_map": { "local-lvm": "node:0" } },
  "vms": { "101": 2, "102": 2, "103": 2, "104": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-basic"
run_manager -f "$WORK/config.json" -n -g

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$WORK/run.log" "CPUs: 8 physical core\(s\), 8 SMT thread\(s\)" "8/8 phys/SMT split detected despite interleaving"
# VM 104 on node 0: physical cpu 2 plus its adjacent sibling cpu 3.
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 2,3 \(Node 0\)" "interleaved sibling paired with its own core"
assert_grep "$WORK/run.log" "\[DRY RUN\] Set Affinity: 8,9 \(Node 1\)" "overflow VM gets node-1 core pair"

# =============================================================================
scenario "-i re-applies IRQ confinement without touching VMs or slices"
write_basic_config
make_irq 40 eth1 "0-15"
make_irq 41 nvme0q2 "0,8"
export SYSTEMD_ETC="$WORK/sysd"
export GRUB_FILE="$WORK/grub"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
run_manager -f "$WORK/config.json" -i

assert_exit_code 0 "$RUN_RC" "exits 0"
assert_grep "$IRQ_PROC_BASE/40/smp_affinity_list" "^0,8$" "movable IRQ re-confined to host cores"
assert_grep "$WORK/run.log" "IRQ confinement: 1 moved, 1 already on host cores" "confinement summary"
assert_not_grep "$WORK/run.log" "PHASE 2" "VM phases skipped"
assert_not_grep "$WORK/qm-calls.log" "^qm set" "no VM touched"
assert_file_absent "$WORK/sysd" "no systemd drop-ins written"
assert_grep "$WORK/grub" '^GRUB_CMDLINE_LINUX_DEFAULT="quiet"$' "GRUB untouched"

# =============================================================================
scenario "hookscript pins vCPUs 1:1 and spreads helper threads in reverse"
mkdir -p "$WORK/qm"
cp "$FIXTURES/qm-mem/101.conf" "$WORK/qm/101.conf"
echo "affinity: 1,9" >> "$WORK/qm/101.conf"
export QM_FIXTURE_DIR="$WORK/qm"
export QEMU_PID_DIR="$WORK/pid-dir"
export PROC_BASE="$WORK/fake-proc"
export TASKSET_CALL_LOG="$WORK/taskset.log"
export VCPU_PIN_LOG="$WORK/cpu-pin.log"
mkdir -p "$WORK/pid-dir" "$WORK/fake-proc/4242/task/5001" "$WORK/fake-proc/4242/task/5002" \
    "$WORK/fake-proc/4242/task/5003" "$WORK/fake-proc/4242/task/5004"
echo 4242 > "$WORK/pid-dir/101.pid"
printf 'CPU 0/KVM\n' > "$WORK/fake-proc/4242/task/5001/comm"
printf 'CPU 1/KVM\n' > "$WORK/fake-proc/4242/task/5002/comm"
printf 'kvm\n' > "$WORK/fake-proc/4242/task/5003/comm"
printf 'vhost-4242\n' > "$WORK/fake-proc/4242/task/5004/comm"

HOOK_RC=0
"$ROOT/extras/vcpu-pin-hook.sh" 101 post-start > "$WORK/hook.log" 2>&1 || HOOK_RC=$?
assert_exit_code 0 "$HOOK_RC" "post-start hook exits 0"
assert_grep "$WORK/taskset.log" "^taskset -pc 1 5001$" "vCPU 0 pinned to first affinity core"
assert_grep "$WORK/taskset.log" "^taskset -pc 9 5002$" "vCPU 1 pinned to second affinity core"
# Helpers are distributed over the affinity cores in REVERSE order (away from
# vCPU 0's core first): main loop -> 9, vhost worker -> 1.
assert_grep "$WORK/taskset.log" "^taskset -pc 9 5003$" "first helper lands on the last affinity core"
assert_grep "$WORK/taskset.log" "^taskset -pc 1 5004$" "second helper round-robins to the next core"
assert_grep "$WORK/hook.log" "pinned 2 vCPU thread\(s\) of VM 101" "hook reports vCPU pinning"
assert_grep "$WORK/hook.log" "distributed 2 helper thread\(s\) of VM 101 over: 9,1" "hook reports helper spread"
assert_grep "$WORK/cpu-pin.log" "vCPU 0 \(tid 5001\) -> CPU 1" "append-log written when VCPU_PIN_LOG is set"

# Other phases are no-ops.
: > "$WORK/taskset.log"
HOOK_RC=0
"$ROOT/extras/vcpu-pin-hook.sh" 101 pre-start > "$WORK/hook.log" 2>&1 || HOOK_RC=$?
assert_exit_code 0 "$HOOK_RC" "pre-start hook exits 0"
assert_not_grep "$WORK/taskset.log" "taskset" "pre-start pins nothing"

# A VM without affinity is skipped gracefully.
mkdir -p "$WORK/qm2"
cp "$FIXTURES/qm-mem/102.conf" "$WORK/qm2/102.conf"
export QM_FIXTURE_DIR="$WORK/qm2"
HOOK_RC=0
"$ROOT/extras/vcpu-pin-hook.sh" 102 post-start > "$WORK/hook.log" 2>&1 || HOOK_RC=$?
assert_exit_code 0 "$HOOK_RC" "hook exits 0 without affinity"
assert_grep "$WORK/hook.log" "VM 102 has no affinity set" "explains the skip"

# =============================================================================
scenario "opt-in tuning_settings disable NUMA balancing/KSM and set the governor"
cat > "$WORK/config.json" <<EOF
{
  "global_settings": { "reserve_host_cores": true, "host_cores": [0, 8], "state_file": "$WORK/state.json" },
  "tuning_settings": {
    "disable_numa_balancing": true,
    "disable_ksm": true,
    "cpu_governor": "performance"
  },
  "vms": { "101": 2 }
}
EOF
export QM_FIXTURE_DIR="$FIXTURES/qm-mem"
export GRUB_FILE="$WORK/grub"
export SYSTEMD_ETC="$WORK/sysd"
export PROC_SYS_BASE="$WORK/fake-procsys"
export SYSCTL_D="$WORK/fake-sysctld"
export KSM_RUN_FILE="$WORK/fake-ksm-run"
export CPUFREQ_BASE="$WORK/fake-cpufreq"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"\n' > "$GRUB_FILE"
mkdir -p "$PROC_SYS_BASE/kernel"
echo 1 > "$PROC_SYS_BASE/kernel/numa_balancing"
echo 1 > "$KSM_RUN_FILE"
for c in 1 2 3 4 5 6 7 9 10 11 12 13 14 15; do
    mkdir -p "$CPUFREQ_BASE/cpu$c/cpufreq"
    echo "schedutil" > "$CPUFREQ_BASE/cpu$c/cpufreq/scaling_governor"
done

# Dry run first: plans only, changes nothing.
run_manager -f "$WORK/config.json" -n -g
assert_exit_code 0 "$RUN_RC" "dry run exits 0"
assert_grep "$WORK/run.log" "\[DRY RUN\] Would disable automatic NUMA balancing" "numa plan printed"
assert_grep "$WORK/fake-procsys/kernel/numa_balancing" "^1$" "dry run leaves numa_balancing alone"

run_manager -f "$WORK/config.json" -g
assert_exit_code 0 "$RUN_RC" "apply exits 0"
assert_grep "$WORK/fake-procsys/kernel/numa_balancing" "^0$" "numa_balancing disabled"
assert_grep "$WORK/fake-sysctld/99-affinity-manager.conf" "^kernel.numa_balancing = 0$" "sysctl persisted"
assert_grep "$WORK/fake-ksm-run" "^2$" "KSM stopped and unmerged"
assert_grep "$WORK/systemctl-calls.log" "^systemctl disable --now ksmtuned$" "ksmtuned disabled"
assert_grep "$WORK/fake-cpufreq/cpu5/cpufreq/scaling_governor" "^performance$" "governor set on a VM core"
assert_grep "$WORK/run.log" "cpufreq governor 'performance' set on 14/14 VM core\(s\)" "all VM cores covered"

# =============================================================================
echo ""
echo "================================================="
echo "  $PASS passed, $FAIL failed"
echo "================================================="
[[ $FAIL -eq 0 ]]
