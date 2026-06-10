#!/bin/bash
set -euo pipefail

# --- HELPER FUNCTIONS ---
log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# --- SYSTEM PATH OVERRIDES (testing hooks) ---
# Every host touchpoint can be redirected at a fake tree so the full pipeline
# is testable in a container (see tests/). Defaults are the real paths.
GRUB_FILE="${GRUB_FILE:-/etc/default/grub}"
SYSTEMD_ETC="${SYSTEMD_ETC:-/etc/systemd}"
PCI_SYS_BASE="${PCI_SYS_BASE:-/sys/bus/pci/devices}"
NODE_SYS_BASE="${NODE_SYS_BASE:-/sys/devices/system/node}"
PROC_SYS_BASE="${PROC_SYS_BASE:-/proc/sys}"
SYSCTL_D="${SYSCTL_D:-/etc/sysctl.d}"
KSM_RUN_FILE="${KSM_RUN_FILE:-/sys/kernel/mm/ksm/run}"
CPUFREQ_BASE="${CPUFREQ_BASE:-/sys/devices/system/cpu}"

usage() {
    echo "Usage: $0 -f <config.json> [-n][-s <hook_script_path>] [-r] [-a [N]]"
    echo "  -f <config.json>:      Path to the JSON configuration file. Required."
    echo "  -n:                    Dry run mode. Plan changes but do not execute them. Optional."
    echo "  -s <hook_script_path>: Path to hook script for VM isolation. Optional."
    echo "  -r:                    Show commands to reset host core pinning. Optional."
    echo "  -a [N]:                Auto-select host cores, consolidated on least GPU-loaded NUMA node. Optional."
    echo "  -b [N]:                Auto-select host cores, balanced across physical sockets (N phys + N SMT per socket). Optional."
    echo "  -g:                    Skip GPU discovery and assignment (force CPU-only). Optional."
    echo "  -i:                    Only re-apply device IRQ confinement, then exit. Optional."
    echo "                         (For boot-time use: see extras/affinity-manager-irq.service.)"
    exit 1
}

# =============================================================================
# --- PARALLELISM HELPERS ---
# Independent per-item work (GPU probing, disk detection, applying VM configs)
# is fanned out across background jobs. A backgrounded function runs in its own
# subshell, so it CANNOT mutate the parent's arrays -- each job writes its result
# to a temp file and the parent reads them back serially after joining. Phase 3
# (planning) is a greedy, order-dependent algorithm and stays sequential.
# =============================================================================

# --- Live progress for parallel phases ---
# Per-job output is captured and replayed after the join (for deterministic log
# order), which would otherwise leave the console silent while slow tasks run --
# looking like a hang. So the PARENT prints progress as it reaps each job:
#   <label>: dispatching N task(s) ...     (phase start)
#     [k/N] <label>: <item> done           (per completed job)
#   <label>: all N task(s) completed in Ts (phase end)
# On bash >= 5.1, `wait -n -p` reports WHICH child finished so the line can name
# the VM/GPU; older bash falls back to anonymous "[k/N] task done" counters.
# Job failures are still reported via result/marker files, never via wait status.
_PAR_LABEL=""
_PAR_TOTAL=0
_PAR_DONE=0
_PAR_T0=0
declare -A _PAR_JOB_NAME
_PAR_HAVE_WAITP=0
if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
    _PAR_HAVE_WAITP=1
fi

# parallel_begin <label> <total>: announce the fan-out and reset progress state.
parallel_begin() {
    _PAR_LABEL=$1
    _PAR_TOTAL=$2
    _PAR_DONE=0
    _PAR_T0=$SECONDS
    _PAR_JOB_NAME=()
    if (( _PAR_TOTAL > 0 )); then
        log "  ${_PAR_LABEL}: dispatching ${_PAR_TOTAL} task(s) async (up to ${PARALLEL_JOBS} concurrent); detailed logs follow once all finish..."
    fi
}

# parallel_track <item-name> <pid>: remember which item a background job handles.
parallel_track() { _PAR_JOB_NAME["$2"]=$1; }

# Reap exactly one finished background job and print a [k/N] progress line.
# Returns 1 when there are no children left to reap.
parallel_reap_one() {
    local pid="" name=""
    if (( _PAR_HAVE_WAITP )); then
        wait -n -p pid 2>/dev/null || true
        [[ -n "$pid" ]] || return 1
        name=${_PAR_JOB_NAME[$pid]:-}
        unset "_PAR_JOB_NAME[$pid]"
    else
        local rc=0
        wait -n 2>/dev/null || rc=$?
        # 127 = no remaining children (indistinguishable from a job exiting 127,
        # but failures are tracked via marker files, so this is cosmetic-safe).
        (( rc == 127 )) && return 1
    fi
    _PAR_DONE=$(( _PAR_DONE + 1 ))
    if [[ -n "$name" ]]; then
        log "    [${_PAR_DONE}/${_PAR_TOTAL}] ${_PAR_LABEL}: ${name} done"
    else
        log "    [${_PAR_DONE}/${_PAR_TOTAL}] ${_PAR_LABEL}: task done"
    fi
    return 0
}

# Block until fewer than PARALLEL_JOBS background jobs are running, reporting
# progress for every job reaped along the way.
parallel_throttle() {
    while (( $(jobs -rp | wc -l) >= PARALLEL_JOBS )); do
        parallel_reap_one || break
    done
}

# Join all remaining jobs of the current phase, with progress, then summarize.
parallel_drain() {
    while (( _PAR_DONE < _PAR_TOTAL )); do
        parallel_reap_one || break
    done
    wait
    if (( _PAR_TOTAL > 0 )); then
        log "  ${_PAR_LABEL}: all ${_PAR_DONE}/${_PAR_TOTAL} task(s) completed in $(( SECONDS - _PAR_T0 ))s."
    fi
}

# Replay a captured job's combined output, routing [WARN]-prefixed lines back to
# stderr so parallel work logs in the same stream order as the sequential path.
replay_captured() {
    local _line
    while IFS= read -r _line; do
        if [[ "$_line" == "[WARN]"* ]]; then
            printf '%s\n' "$_line" >&2
        else
            printf '%s\n' "$_line"
        fi
    done < "$1"
}

# =============================================================================
# --- STATE MANAGEMENT FUNCTIONS ---
# =============================================================================

create_state_file() {
    local state_file="$STATE_FILE"
    local timestamp=$(date -Iseconds)

    log "Creating state file: $state_file (applied=$STATE_APPLIED)"
    cat > "$state_file" << STATEEOF
{
  "metadata": {
    "timestamp": "$timestamp",
        "version": "11.6-disk-locality+irq-confine+parallel",
    "config_file": "$CONFIG_FILE",
    "dry_run": $([ $DRY_RUN -eq 1 ] && echo "true" || echo "false"),
    "applied": $STATE_APPLIED
  },
  "core_assignments": {
STATEEOF

    local vm_count=0
    local total_vms=${#VMS_TO_CONFIGURE[@]}
    local sorted_keys=$(for key in "${!VM_ASSIGNMENTS[@]}"; do echo "$key"; done | sort -n)

    for vmid in $sorted_keys; do
        vm_count=$((vm_count + 1))
        local plan=${VM_ASSIGNMENTS[$vmid]}
        local cpu_count=${VMS_TO_CONFIGURE[$vmid]}
        
        # [FIX] Changed delimiter from ':' to '|' to handle PCI IDs correctly
        local assigned_cores_str=$(echo "$plan" | sed -n 's/.*cores=\([^|]*\).*/\1/p')
        local assigned_node=$(echo "$plan" | sed -n 's/.*|node=\([^|]*\).*/\1/p')
        local gpu_info=$(echo "$plan" | sed -n 's/.*gpu_pci=\([^|]*\).*/\1/p')
        local mdev_info=$(echo "$plan" | sed -n 's/.*mdev=\([^|]*\).*/\1/p')
                local disk_node=$(echo "$plan" | sed -n 's/.*disk_node=\([^|]*\).*/\1/p')
                local disk_source=$(echo "$plan" | sed -n 's/.*disk_source=\([^|]*\).*/\1/p')
                local disk_match=$(echo "$plan" | sed -n 's/.*disk_match=\([^|]*\).*/\1/p')

        IFS=',' read -ra assigned_cores_array <<< "$assigned_cores_str"

        cat >> "$state_file" << VMSTATEEOF
    "$vmid": {
      "name": "vm-${vmid}",
      "cores": $cpu_count,
      "numa_node": $assigned_node,
            "disk_preference_node": $([ -n "$disk_node" ] && echo "$disk_node" || echo "null"),
            "disk_preference_source": $([ -n "$disk_source" ] && echo "\"$disk_source\"" || echo "null"),
            "disk_locality_matched": $([ -n "$disk_match" ] && echo "$disk_match" || echo "null"),
      "gpu_assigned": $([ -n "$gpu_info" ] && echo "\"$gpu_info ($mdev_info)\"" || echo "null"),
      "assigned_physical_cores":[$(IFS=','; echo "${assigned_cores_array[*]}")]
    }$([ $vm_count -lt $total_vms ] && echo "," || echo "")
VMSTATEEOF
    done

    cat >> "$state_file" << STATEEOF2
  }
}
STATEEOF2
}

socket_to_node() {
    local socket_id=$1
    local cpu_id

    for cpu_id in $(seq 0 "$SMT_END"); do
        if [[ -v CPU_TO_SOCKET["$cpu_id"] && "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" ]]; then
            echo "${CPU_TO_NODE[$cpu_id]}"
            return 0
        fi
    done

    return 1
}

resolve_locality_value_to_node() {
    local locality_value=$1
    local resolved_node=""

    [[ -z "$locality_value" || "$locality_value" == "null" ]] && return 1

    if [[ "$locality_value" =~ ^node:([0-9]+)$ ]]; then
        resolved_node=${BASH_REMATCH[1]}
    elif [[ "$locality_value" =~ ^socket:([0-9]+)$ ]]; then
        resolved_node=$(socket_to_node "${BASH_REMATCH[1]}" 2>/dev/null || true)
    elif [[ "$locality_value" =~ ^[0-9]+$ ]]; then
        if [[ " ${NUMA_NODE_IDS[*]} " =~ " ${locality_value} " ]]; then
            resolved_node=$locality_value
        else
            resolved_node=$(socket_to_node "$locality_value" 2>/dev/null || true)
        fi
    fi

    [[ -n "$resolved_node" ]] || return 1
    echo "$resolved_node"
}

get_vm_boot_disk_device() {
    local vm_config=$1
    local boot_value boot_entry disk_line

    boot_value=$(echo "$vm_config" | sed -n 's/^boot:.*order=//p' | tr -d ' ')
    if [[ -n "$boot_value" ]]; then
        IFS=';' read -ra boot_entries <<< "$boot_value"
        for boot_entry in "${boot_entries[@]}"; do
            if [[ "$boot_entry" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]]; then
                disk_line=$(echo "$vm_config" | grep -m1 "^${boot_entry}:" || true)
                if [[ -n "$disk_line" && "$disk_line" != *"media=cdrom"* ]]; then
                    echo "$boot_entry"
                    return 0
                fi
            fi
        done
    fi

    echo "$vm_config" | grep -E '^(scsi|virtio|sata|ide)[0-9]+:' | grep -v 'media=cdrom' | head -n1 | cut -d: -f1
}

get_vm_disk_locator() {
    local vm_config=$1
    local boot_disk disk_line

    boot_disk=$(get_vm_boot_disk_device "$vm_config")
    [[ -n "$boot_disk" ]] || return 1

    disk_line=$(echo "$vm_config" | grep -m1 "^${boot_disk}:" || true)
    [[ -n "$disk_line" ]] || return 1

    echo "$disk_line" | awk '{print $2}' | cut -d',' -f1
}

resolve_block_device_node() {
    local device_path=$1
    local device_name parent_name candidate numa_path numa_node sysfs_path current_path

    [[ -n "$device_path" ]] || return 1
    device_name=$(basename "$device_path")
    parent_name="$device_name"

    if command -v lsblk &> /dev/null; then
        parent_name=$(lsblk -ndo PKNAME "$device_path" 2>/dev/null | head -n1)
        [[ -n "$parent_name" ]] || parent_name="$device_name"
    fi

    for candidate in "$parent_name" "$device_name"; do
        [[ -n "$candidate" ]] || continue
        numa_path="/sys/class/block/${candidate}/device/numa_node"
        if [[ -f "$numa_path" ]]; then
            numa_node=$(cat "$numa_path" 2>/dev/null || echo "")
            if [[ "$numa_node" =~ ^[0-9]+$ ]]; then
                echo "$numa_node"
                return 0
            fi
        fi

        sysfs_path=$(readlink -f "/sys/class/block/${candidate}/device" 2>/dev/null || true)
        current_path="$sysfs_path"
        while [[ -n "$current_path" && "$current_path" != "/" ]]; do
            numa_path="${current_path}/numa_node"
            if [[ -f "$numa_path" ]]; then
                numa_node=$(cat "$numa_path" 2>/dev/null || echo "")
                if [[ "$numa_node" =~ ^[0-9]+$ ]]; then
                    echo "$numa_node"
                    return 0
                fi
            fi
            current_path=$(dirname "$current_path")
        done
    done

    return 1
}

resolve_lvm_path_node() {
    local lvm_path=$1
    local vg_name pv_path resolved_node

    command -v lvs &> /dev/null || return 1
    command -v vgs &> /dev/null || return 1

    vg_name=$(lvs --noheadings -o vg_name "$lvm_path" 2>/dev/null | xargs)
    [[ -n "$vg_name" ]] || return 1

    while IFS= read -r pv_path; do
        pv_path=$(echo "$pv_path" | xargs)
        [[ -n "$pv_path" && "$pv_path" == /dev/* ]] || continue
        resolved_node=$(resolve_block_device_node "$pv_path" 2>/dev/null || true)
        if [[ -n "$resolved_node" ]]; then
            echo "$resolved_node"
            return 0
        fi
    done < <(vgs --noheadings -o pv_name "$vg_name" 2>/dev/null)

    return 1
}

resolve_storage_id_node() {
    local storage_id=$1
    local vg_name resolved_node pv_path

    [[ -n "$storage_id" ]] || return 1

    # Local-LVM style: storage ID matches VG name (e.g., VMs8)
    if command -v vgs &> /dev/null; then
        vg_name=$(vgs --noheadings -o vg_name "$storage_id" 2>/dev/null | xargs)
        if [[ -n "$vg_name" ]]; then
            while IFS= read -r pv_path; do
                pv_path=$(echo "$pv_path" | xargs)
                [[ -n "$pv_path" && "$pv_path" == /dev/* ]] || continue
                resolved_node=$(resolve_block_device_node "$pv_path" 2>/dev/null || true)
                if [[ -n "$resolved_node" ]]; then
                    echo "$resolved_node"
                    return 0
                fi
            done < <(vgs --noheadings -o pv_name "$vg_name" 2>/dev/null)
        fi
    fi

    return 1
}

resolve_path_node() {
    local target_path=$1
    local resolved_path source_device lvm_node

    [[ -n "$target_path" ]] || return 1

    resolved_path=$(readlink -f "$target_path" 2>/dev/null || echo "$target_path")
    if [[ -b "$resolved_path" ]]; then
        resolve_block_device_node "$resolved_path"
        if [[ $? -eq 0 ]]; then
            return 0
        fi

        lvm_node=$(resolve_lvm_path_node "$target_path" 2>/dev/null || true)
        if [[ -z "$lvm_node" && "$resolved_path" != "$target_path" ]]; then
            lvm_node=$(resolve_lvm_path_node "$resolved_path" 2>/dev/null || true)
        fi
        if [[ -n "$lvm_node" ]]; then
            echo "$lvm_node"
            return 0
        fi
    fi

    if [[ -e "$resolved_path" ]] && command -v df &> /dev/null; then
        source_device=$(df --output=source "$resolved_path" 2>/dev/null | tail -n1 | xargs)
        if [[ "$source_device" == /dev/* ]]; then
            resolve_block_device_node "$source_device"
            return $?
        fi
    fi

    return 1
}

detect_vm_disk_preference() {
    local vmid=$1
    local configured_value configured_node vm_config disk_locator storage_id storage_node resolved_path resolved_node

    configured_value=$(jq -r --arg vmid "$vmid" '
        .disk_settings.vm_node_map[$vmid]
        // .vm_disk_node_map[$vmid]
        // .storage_settings.vm_node_map[$vmid]
        // empty
    ' "$CONFIG_FILE")
    if [[ -n "$configured_value" ]]; then
        configured_node=$(resolve_locality_value_to_node "$configured_value" 2>/dev/null || true)
        if [[ -n "$configured_node" ]]; then
            echo "$configured_node|config:vm_node_map"
            return 0
        fi
    fi

    vm_config=$(qm config "$vmid" 2>/dev/null || true)
    [[ -n "$vm_config" ]] || return 1

    disk_locator=$(get_vm_disk_locator "$vm_config")
    [[ -n "$disk_locator" ]] || return 1

    if [[ "$disk_locator" != /* ]]; then
        storage_id=${disk_locator%%:*}
        configured_value=$(jq -r --arg storage "$storage_id" '
            .disk_settings.storage_node_map[$storage]
            // .storage_node_map[$storage]
            // .storage_settings.node_map[$storage]
            // empty
        ' "$CONFIG_FILE")
        if [[ -n "$configured_value" ]]; then
            storage_node=$(resolve_locality_value_to_node "$configured_value" 2>/dev/null || true)
            if [[ -n "$storage_node" ]]; then
                echo "$storage_node|config:storage_node_map:${storage_id}"
                return 0
            fi
        fi

        # Offline-safe fallback: infer NUMA node from storage ID via LVM VG->PV mapping.
        storage_node=$(resolve_storage_id_node "$storage_id" 2>/dev/null || true)
        if [[ -n "$storage_node" ]]; then
            echo "$storage_node|storage:${storage_id}"
            return 0
        fi
    fi

    resolved_path=""
    if [[ "$disk_locator" == /* ]]; then
        resolved_path=$disk_locator
    elif command -v pvesm &> /dev/null; then
        resolved_path=$(pvesm path "$disk_locator" 2>/dev/null || true)
    fi

    if [[ -n "$resolved_path" ]]; then
        resolved_node=$(resolve_path_node "$resolved_path" 2>/dev/null || true)
        if [[ -n "$resolved_node" ]]; then
            echo "$resolved_node|path:${resolved_path}"
            return 0
        fi
    fi

    return 1
}

# --- ARGUMENT PARSING ---
CONFIG_FILE=""
DRY_RUN=0
HOOK_SCRIPT_PATH=""
RESET_HOST_PINNING=0
AUTO_HOST_CORES=0
BALANCE_SOCKETS=0
CORES_PER_NUMA=1
SKIP_GPU=0
CONFINE_IRQS_ONLY=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--config) CONFIG_FILE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -s|--hook-script) HOOK_SCRIPT_PATH="$2"; shift 2 ;;
        -r|--reset-host-pinning) RESET_HOST_PINNING=1; shift ;;
        -a|--auto-host-cores)
            AUTO_HOST_CORES=1
            if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then CORES_PER_NUMA="$2"; shift 2; else shift; fi
            ;;
        -b|--balance-sockets)
            AUTO_HOST_CORES=1
            BALANCE_SOCKETS=1
            if [[ $# -gt 1 && "$2" =~ ^[0-9]+$ ]]; then CORES_PER_NUMA="$2"; shift 2; else shift; fi
            ;;
        -g|--no-gpu) SKIP_GPU=1; shift ;;
        -i|--confine-irqs-only) CONFINE_IRQS_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown option: $1" ;;
    esac
done

if [[ -z "$CONFIG_FILE" ]]; then error "Configuration file (-f) is required."; fi
if [[ ! -f "$CONFIG_FILE" ]]; then error "Configuration file not found."; fi
# qm only accepts hookscripts as storage volume IDs (e.g. local:snippets/hook.sh)
# on a storage with the 'snippets' content type -- a plain filesystem path fails
# at apply time on every VM. Catch it up front.
if [[ -n "$HOOK_SCRIPT_PATH" && "$HOOK_SCRIPT_PATH" != *:* ]]; then
    warn "Hook script '$HOOK_SCRIPT_PATH' looks like a filesystem path; qm expects a storage volume ID (e.g. local:snippets/hook.sh) and will reject this."
fi
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then error "Run as root or use dry-run."; fi
for cmd in qm lscpu jq bc lspci; do
    if ! command -v "$cmd" &> /dev/null; then error "Required command '$cmd' not found."; fi
done

# --- SINGLE-INSTANCE LOCK ---
# Two concurrent runs race on the config backup, the systemd/GRUB writes, and
# GPU slot accounting. Serialize via flock; LOCK_FILE is overridable for tests.
LOCK_FILE="${LOCK_FILE:-/run/lock/affinity-manager.lock}"
if command -v flock &> /dev/null; then
    # Probe writability in a subshell: putting 2>/dev/null on the real exec
    # would permanently redirect the script's stderr along with fd 9.
    if ! ( exec 9>"$LOCK_FILE" ) 2>/dev/null; then
        LOCK_FILE="/tmp/affinity-manager.lock"
    fi
    exec 9>"$LOCK_FILE"
    flock -n 9 || error "Another instance is already running (lock: $LOCK_FILE)."
else
    warn "flock not available; concurrent runs are not guarded against."
fi

# Handle host core pinning reset
if [[ $RESET_HOST_PINNING -eq 1 ]]; then
    log "Resetting all host core pinning..."
    echo ""
    echo "  # Reset AllowedCPUs on slices"
    echo "  systemctl set-property system.slice AllowedCPUs=\"\""
    echo "  systemctl set-property user.slice AllowedCPUs=\"\""
    echo "  systemctl set-property init.scope AllowedCPUs=\"\""
    echo "  systemctl set-property --runtime qemu.slice AllowedCPUs=\"\""
    echo ""
    echo "  # Remove CPUAffinity drop-in for PID 1 (systemd manager)"
    echo "  rm -f ${SYSTEMD_ETC}/system.conf.d/99-host-cores.conf"
    echo ""
    echo "  # Remove AllowedCPUs drop-in for qemu.slice (and the obsolete machine.slice one)"
    echo "  rm -f ${SYSTEMD_ETC}/system/qemu.slice.d/99-vm-cores.conf"
    echo "  rm -f ${SYSTEMD_ETC}/system/machine.slice.d/99-vm-cores.conf"
    echo ""
    echo "  # Reload systemd to apply changes"
    echo "  systemctl daemon-reexec"
    echo ""
    log "Run the above commands manually as root to reset all pinning."
    exit 0
fi

# --- PARALLELISM CAP ---
# Cap concurrent background jobs at global_settings.parallel_jobs, else the host
# CPU count (nproc), floor 1. Set parallel_jobs=1 to force fully sequential work.
PARALLEL_JOBS=$(jq -r '.global_settings.parallel_jobs // empty' "$CONFIG_FILE")
if [[ ! "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || (( PARALLEL_JOBS < 1 )); then
    PARALLEL_JOBS=$(nproc 2>/dev/null || echo 1)
fi
(( PARALLEL_JOBS >= 1 )) || PARALLEL_JOBS=1
log "Parallelism: up to ${PARALLEL_JOBS} concurrent job(s) for discovery and execution."

# --- STATE FILE LOCATION ---
# Honor global_settings.state_file (previously read by nothing and silently
# ignored). Dry runs write to a separate .dryrun file so a preview never
# clobbers the record of the last real apply.
STATE_FILE=$(jq -r '.global_settings.state_file // empty' "$CONFIG_FILE")
if [[ -z "$STATE_FILE" || "$STATE_FILE" == "null" ]]; then
    STATE_FILE="manager_state.json"
fi
if [[ $DRY_RUN -eq 1 ]]; then
    STATE_FILE="${STATE_FILE}.dryrun"
fi

# The state file is first written when planning completes (so a failed apply
# still leaves a record of what was attempted) and rewritten with applied=true
# only after Phase 4 succeeds. applied=false therefore means "planned, but not
# (fully) on the host".
STATE_APPLIED="false"


# =============================================================================
# --- PHASE 1: TOPOLOGY DISCOVERY (CPU) ---
# =============================================================================
log "--- PHASE 1: Discovering CPU Topology ---"

CPU_CONFIG_STRING=$(jq -r '.global_settings.cpu_config_string // "host"' "$CONFIG_FILE")
HOST_CORES_JSON=$(jq -r '.global_settings.host_cores //[]' "$CONFIG_FILE")
RESERVE_HOST_CORES=$(jq -r '.global_settings.reserve_host_cores' "$CONFIG_FILE")

declare -A CPU_TO_CORE CPU_TO_NODE CPU_TO_SOCKET SOCKET_IDS MIN_CORE_PER_SOCKET CORES_TO_RESERVE_MAP
declare -A CPU_IS_SMT CPU_SIBLINGS CORE_KEY_CPUS
declare -a NUMA_NODE_IDS CORES_TO_RESERVE ALL_PHYS_CPUS ALL_SMT_CPUS

# Physical-vs-SMT classification comes from the lscpu core map: the first CPU
# listed for each socket:core is the "physical" (primary) thread, the rest are
# its SMT siblings. The old assumption -- CPU IDs 0..max_core_id are physical
# and the rest SMT -- only holds for Intel-style enumeration and silently
# misclassifies hosts with interleaved sibling IDs (common on AMD EPYC) or
# offline CPUs.
MAX_CPU_ID=0
lscpu_output=$(lscpu -p=CPU,CORE,SOCKET,NODE 2>&1)
while IFS= read -r line; do
    [[ "$line" =~ ^# || -z "$line" ]] && continue
    IFS=',' read -r cpu core socket node <<<"$line"
    node=${node:-0}; socket=${socket:-0}
    CPU_TO_CORE["$cpu"]=$core; CPU_TO_NODE["$cpu"]=$node; CPU_TO_SOCKET["$cpu"]=$socket
    SOCKET_IDS["$socket"]=1
    if (( cpu > MAX_CPU_ID )); then MAX_CPU_ID=$cpu; fi
    if [[ ! " ${NUMA_NODE_IDS[*]} " =~ " ${node} " ]]; then NUMA_NODE_IDS+=("$node"); fi
    if [[ -z "$core" ]]; then
        CPU_IS_SMT["$cpu"]=0
        ALL_PHYS_CPUS+=("$cpu")
        continue
    fi
    core_key="${socket}:${core}"
    if [[ -v CORE_KEY_CPUS["$core_key"] ]]; then
        CPU_IS_SMT["$cpu"]=1
        ALL_SMT_CPUS+=("$cpu")
        CORE_KEY_CPUS["$core_key"]+=" $cpu"
    else
        CPU_IS_SMT["$cpu"]=0
        ALL_PHYS_CPUS+=("$cpu")
        CORE_KEY_CPUS["$core_key"]=$cpu
    fi
    if [[ ! -v MIN_CORE_PER_SOCKET["$socket"] || "$core" -lt "${MIN_CORE_PER_SOCKET["$socket"]}" ]]; then
        MIN_CORE_PER_SOCKET["$socket"]=$core
    fi
done <<< "$lscpu_output"
IFS=$'\n' NUMA_NODE_IDS=($(sort -n <<<"${NUMA_NODE_IDS[*]}")); unset IFS

# Second pass: full sibling map (cpu -> the other thread(s) on its core).
for core_key in "${!CORE_KEY_CPUS[@]}"; do
    core_cpus=(${CORE_KEY_CPUS[$core_key]})
    if (( ${#core_cpus[@]} < 2 )); then continue; fi
    for cpu in "${core_cpus[@]}"; do
        sibs=()
        for sib in "${core_cpus[@]}"; do
            if [[ "$sib" != "$cpu" ]]; then sibs+=("$sib"); fi
        done
        CPU_SIBLINGS["$cpu"]="${sibs[*]}"
    done
done
unset core_key core_cpus sibs sib

# SMT_END doubles as the maximum CPU id for iteration bounds throughout the
# script; classification itself is map-based via CPU_IS_SMT.
SMT_END=$MAX_CPU_ID

log "  CPUs: ${#ALL_PHYS_CPUS[@]} physical core(s), ${#ALL_SMT_CPUS[@]} SMT thread(s), max CPU id $MAX_CPU_ID"

# --- Auto-select host cores function (CONSOLIDATED TO ONE NODE) ---
auto_select_host_cores() {
    local total_phys_to_reserve=$1
    local target_node=$2
    local auto_host_cores=()
    
    local node_phys_cores=()
    local node_smt_cores=()
    
    # Only scan the target node for available cores
    for cpu_id in $(seq 0 $SMT_END); do
        if [[ -v CPU_TO_NODE["$cpu_id"] && "${CPU_TO_NODE[$cpu_id]}" == "$target_node" ]]; then
            if [[ "${CPU_IS_SMT[$cpu_id]:-0}" == "0" ]]; then
                node_phys_cores+=("$cpu_id")
            else
                node_smt_cores+=("$cpu_id")
            fi
        fi
    done
    
    IFS=$'\n' sorted_phys_cores=($(sort -n <<<"${node_phys_cores[*]}")); unset IFS
    IFS=$'\n' sorted_smt_cores=($(sort -n <<<"${node_smt_cores[*]}")); unset IFS
    
    local phys_cores_added=0
    for core in "${sorted_phys_cores[@]}"; do
        if (( phys_cores_added < total_phys_to_reserve )); then
            auto_host_cores+=("$core")
            phys_cores_added=$((phys_cores_added + 1))
        fi
    done
    
    local smt_cores_added=0
    for core in "${sorted_smt_cores[@]}"; do
        if (( smt_cores_added < total_phys_to_reserve )); then
            auto_host_cores+=("$core")
            smt_cores_added=$((smt_cores_added + 1))
        fi
    done
    
    # Format into JSON array
    local json_cores="["
    local first=true
    for core in "${auto_host_cores[@]}"; do
        if [[ "$first" == "true" ]]; then
            json_cores+="$core"
            first=false
        else
            json_cores+=",$core"
        fi
    done
    json_cores+="]"
    echo "$json_cores"
}

# Handle -a / -b auto-select host cores (after topology discovery)
if [[ $AUTO_HOST_CORES -eq 1 ]]; then
    log "Auto-selection requested, overriding config host_cores..."
    
    if [[ $BALANCE_SOCKETS -eq 1 ]]; then
        # -b: pick CORES_PER_NUMA phys + CORES_PER_NUMA SMT per physical socket
        log "Socket-balanced selection: Auto-selecting $CORES_PER_NUMA physical + $CORES_PER_NUMA SMT core(s) per socket..."
        local_host_cores=()
        IFS=$'\n' sorted_socket_ids=($(echo "${!SOCKET_IDS[@]}" | tr ' ' '\n' | sort -n)); unset IFS
        for _sock_id in "${sorted_socket_ids[@]}"; do
            _sock_phys=(); _sock_smt=()
            for _cpu_id in $(seq 0 $SMT_END); do
                [[ -v CPU_TO_SOCKET["$_cpu_id"] && "${CPU_TO_SOCKET[$_cpu_id]}" == "$_sock_id" ]] || continue
                if [[ "${CPU_IS_SMT[$_cpu_id]:-0}" == "0" ]]; then
                    _sock_phys+=("$_cpu_id")
                else
                    _sock_smt+=("$_cpu_id")
                fi
            done
            IFS=$'\n' _sorted_phys=($(sort -n <<<"${_sock_phys[*]}")); unset IFS
            IFS=$'\n' _sorted_smt=($(sort -n <<<"${_sock_smt[*]}")); unset IFS
            _p=0; for _c in "${_sorted_phys[@]}"; do
                (( _p < CORES_PER_NUMA )) && { local_host_cores+=("$_c"); (( _p++ )) || true; }
            done
            _s=0; for _c in "${_sorted_smt[@]}"; do
                (( _s < CORES_PER_NUMA )) && { local_host_cores+=("$_c"); (( _s++ )) || true; }
            done
            log "  Socket $_sock_id: reserved cores added"
        done
        unset _sock_id _sock_phys _sock_smt _sorted_phys _sorted_smt _p _s _c sorted_socket_ids
        # Convert to JSON
        HOST_CORES_JSON="["
        _first=true
        for _c in "${local_host_cores[@]}"; do
            [[ "$_first" == "true" ]] && HOST_CORES_JSON+="$_c" || HOST_CORES_JSON+=",$_c"
            _first=false
        done
        HOST_CORES_JSON+="]"
        unset local_host_cores _first _c
        log "Socket-balanced host cores: $HOST_CORES_JSON"
    else
        # -a: original consolidation onto the least GPU-loaded NUMA node
        declare -A _node_gpu_slots
        for _nid in "${NUMA_NODE_IDS[@]}"; do _node_gpu_slots["$_nid"]=0; done
        _target_vram=$(jq -r '.gpu_settings.required_vram_mb // 2048' "$CONFIG_FILE")
        # Same candidate sources as discover_gpus: config override first, then
        # lspci auto-detection. (Previously only config-listed GPUs were counted,
        # so auto-detected setups always scored 0 and silently picked node 0.)
        _pci_list=$(jq -r '(.gpu_settings.gpu_pci_ids // (.gpu_settings.gpu_profile_map // {} | keys))[]' \
            "$CONFIG_FILE" 2>/dev/null)
        if [[ -z "$_pci_list" && $SKIP_GPU -eq 0 ]]; then
            _pci_list=$(lspci -D -nn | grep -E "\[03[0-9a-fA-F]{2}\]" | grep -i nvidia | cut -d' ' -f1 || true)
        fi
        while IFS= read -r _pci; do
            [[ -z "$_pci" ]] && continue
            _pci_node=$(cat "${PCI_SYS_BASE}/${_pci}/numa_node" 2>/dev/null || echo -1)
            [[ "$_pci_node" == "-1" ]] && _pci_node=0
            _prof=$(jq -r --arg p "$_pci" \
                '.gpu_settings.gpu_profile_map[$p] // .gpu_settings.mdev_override // "nvidia-47"' \
                "$CONFIG_FILE")
            _avail=$(cat "${PCI_SYS_BASE}/${_pci}/mdev_supported_types/${_prof}/available_instances" 2>/dev/null || echo 0)
            _mem=$(nvidia-smi --id="$_pci" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo 0)
            if [[ "$_mem" =~ ^[0-9]+$ ]] && (( _mem > 0 )); then
                _max_by_vram=$(( _mem / _target_vram ))
                (( _max_by_vram < _avail )) && _avail=$_max_by_vram
            fi
            _node_gpu_slots["$_pci_node"]=$(( ${_node_gpu_slots[$_pci_node]:-0} + _avail ))
        done <<< "$_pci_list"
        unset _pci_list
        TARGET_NODE=${NUMA_NODE_IDS[0]}
        _min_slots=${_node_gpu_slots[${NUMA_NODE_IDS[0]}]:-0}
        for _nid in "${NUMA_NODE_IDS[@]}"; do
            if (( ${_node_gpu_slots[$_nid]:-0} < _min_slots )); then
                _min_slots=${_node_gpu_slots[$_nid]:-0}
                TARGET_NODE=$_nid
            fi
        done
        log "  Least GPU-loaded NUMA node: Node $TARGET_NODE (gpu_slots=${_min_slots})"
        unset _node_gpu_slots _target_vram _pci _pci_node _prof _avail _mem _max_by_vram _min_slots _nid

        # Calculate total physical cores to reserve (e.g., -a 2 on a 2-node system = 4 total physical)
        TOTAL_PHYS_TO_RESERVE=$(( CORES_PER_NUMA * ${#NUMA_NODE_IDS[@]} ))

        log "Consolidating host cores: Auto-selecting $TOTAL_PHYS_TO_RESERVE physical + $TOTAL_PHYS_TO_RESERVE SMT core(s) strictly on NUMA Node $TARGET_NODE..."

        HOST_CORES_JSON=$(auto_select_host_cores "$TOTAL_PHYS_TO_RESERVE" "$TARGET_NODE")
        log "Auto-selected host cores: $HOST_CORES_JSON"
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        log "  Created backup: ${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        if jq --argjson host_cores "$HOST_CORES_JSON" '.global_settings.host_cores = $host_cores' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"; then
            mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
            log "  Updated host_cores in config file: $CONFIG_FILE"
        else
            error "Failed to update config file with auto-selected host cores"
        fi
    else
        log "  DRY RUN: Would update host_cores in config file: $CONFIG_FILE"
    fi

    while IFS= read -r core_id; do
        if [[ "$core_id" =~ ^[0-9]+$ ]]; then
            node_id=""
            for cpu in $(seq 0 $SMT_END); do
                if [[ -v CPU_TO_NODE["$cpu"] && "$cpu" == "$core_id" ]]; then
                    node_id=${CPU_TO_NODE["$cpu"]}; break
                fi
            done
            log "  NUMA node $node_id: Selected core $core_id"
        fi
    done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
fi

# Convert a sorted list of CPU IDs to compact range notation (e.g., "2-21,24-43")
cpus_to_ranges() {
    local cpus=($(echo "$@" | tr ' ' '\n' | sort -n))
    if (( ${#cpus[@]} == 0 )); then
        echo ""
        return 0
    fi
    local ranges=""
    local start=${cpus[0]}
    local prev=${cpus[0]}
    for ((i=1; i<${#cpus[@]}; i++)); do
        if (( cpus[i] == prev + 1 )); then
            prev=${cpus[i]}
        else
            if (( start == prev )); then
                ranges+="${start},"
            else
                ranges+="${start}-${prev},"
            fi
            start=${cpus[i]}
            prev=${cpus[i]}
        fi
    done
    if (( start == prev )); then
        ranges+="${start}"
    else
        ranges+="${start}-${prev}"
    fi
    echo "$ranges"
}

# =============================================================================
# --- DEVICE IRQ CONFINEMENT ---
# Pinning vCPU threads, the systemd slices, and the boot-time GRUB isolcpus
# params is still not enough at RUNTIME: non-managed device hardware IRQs (and
# their NET_RX/NET_TX softirq chains) default to a broad affinity mask that
# includes VM-dedicated cores. A busy single-queue NIC can then park its whole
# interrupt load on one VM's core, starving that VM relative to its siblings.
# These helpers steer movable device IRQs onto the reserved host cores -- the
# same place the CPUAffinity drop-ins send host work. (The isolcpus=managed_irq
# GRUB param set below handles *managed* IRQs, e.g. NVMe blk-mq, but only after
# a reboot; this handles the rest, live.)
# =============================================================================

# irq_mask_hits_vm_core <cpulist>
#   Returns 0 (true)  if the smp_affinity_list (e.g. "0-43" or "6-8,28-30")
#                     includes any CPU that is NOT a reserved host core.
#   Returns 1 (false) if every listed CPU is a host core (already confined).
irq_mask_hits_vm_core() {
    local list="$1"
    local token lo hi cpu
    local -a tokens
    IFS=',' read -ra tokens <<< "$list"
    for token in "${tokens[@]}"; do
        if [[ -z "$token" ]]; then continue; fi
        if [[ "$token" == *-* ]]; then
            lo=${token%%-*}; hi=${token##*-}
        else
            lo=$token; hi=$token
        fi
        # Only reason about plain numeric ranges; skip anything exotic.
        if [[ ! "$lo" =~ ^[0-9]+$ || ! "$hi" =~ ^[0-9]+$ ]]; then continue; fi
        for (( cpu=lo; cpu<=hi; cpu++ )); do
            if [[ ! -v CORES_TO_RESERVE_MAP["$cpu"] ]]; then
                return 0   # a VM core is in the mask
            fi
        done
    done
    return 1   # entirely host cores
}

# confine_device_irqs
#   Rewrites /proc/irq/<N>/smp_affinity_list of every movable device IRQ that
#   currently overlaps a VM core, steering it onto the reserved host cores, then
#   re-reads to verify the write took. Idempotent (IRQs already on host cores are
#   skipped), honors DRY_RUN, and reports managed IRQs (e.g. NVMe blk-mq, which
#   reject affinity writes with -EIO) as "not movable" rather than failing the
#   run. Opt out with global_settings.confine_device_irqs=false.
confine_device_irqs() {
    # `== false` idiom (not `// true`): jq's // coalesces a real boolean false,
    # which would silently ignore an explicit opt-out.
    local confine
    confine=$(jq -r 'if .global_settings.confine_device_irqs == false then "false" else "true" end' "$CONFIG_FILE")
    if [[ "$confine" != "true" ]]; then
        log "  Device IRQ confinement disabled (global_settings.confine_device_irqs=false); skipping."
        return 0
    fi

    if [[ ${#CORES_TO_RESERVE[@]} -eq 0 ]]; then
        warn "  No reserved host cores; skipping device IRQ confinement."
        return 0
    fi

    # Sorted, de-duplicated, comma-separated host-core cpulist (e.g. "0,22,44,66").
    local host_list
    host_list=$(printf '%s\n' "${CORES_TO_RESERVE[@]}" | sort -nu | tr '\n' ',')
    host_list=${host_list%,}

    # irqbalance would dynamically undo this static placement.
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        warn "  irqbalance is ACTIVE and will likely undo static IRQ placement."
        warn "    Consider: systemctl disable --now irqbalance   (or set IRQBALANCE_BANNED_CPUS)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "  [DRY RUN] Would confine movable device IRQs overlapping VM cores onto host cores: $host_list"
    else
        log "  Confining movable device IRQs onto host cores: $host_list"
    fi

    # Overridable base purely for testing against a fake /proc/irq tree.
    local base="${IRQ_PROC_BASE:-/proc/irq}"
    local path irq af list after eff dev_name sub bn
    local considered=0 moved=0 skipped=0 managed_ok=0 stuck=0
    local -A stuck_by_dev   # base device name -> count of IRQs stuck on VM cores

    for path in "$base"/[0-9]*; do
        if [[ ! -d "$path" ]]; then continue; fi
        irq=${path##*/}

        # Identify device IRQs by their /proc/irq/<N>/<device> subdir (kernel 6.8
        # has no 'actions' file); fall back to the 'actions' file on older kernels.
        dev_name=""
        for sub in "$path"/*/; do
            if [[ ! -d "$sub" ]]; then continue; fi
            dev_name=${sub%/}; dev_name=${dev_name##*/}
            break
        done
        if [[ -z "$dev_name" && -r "$path/actions" ]]; then
            dev_name=$(<"$path/actions")
        fi
        # No device association -> not a device IRQ; leave it untouched.
        if [[ -z "$dev_name" ]]; then continue; fi

        af="$path/smp_affinity_list"
        if [[ ! -r "$af" ]]; then continue; fi
        list=$(<"$af")
        considered=$((considered + 1))

        # Idempotent: mask already constrained to host cores -> nothing to do.
        if ! irq_mask_hits_vm_core "$list"; then
            skipped=$((skipped + 1))
            continue
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            log "    [plan] IRQ $irq ($dev_name): $list -> $host_list"
            moved=$((moved + 1))
            continue
        fi

        # Try to constrain the mask. Managed IRQs (NVMe blk-mq) reject the write
        # with -EIO. 2>/dev/null precedes the redirect so an open-time EACCES/EPERM
        # is suppressed too (it would otherwise leak past a trailing 2>/dev/null).
        if echo "$host_list" 2>/dev/null > "$af"; then
            after=$(<"$af")
            if ! irq_mask_hits_vm_core "$after"; then
                log "    IRQ $irq ($dev_name): $list -> $after"
                moved=$((moved + 1))
                continue
            fi
            # Wrote but it did not take (rare) -> fall through to the stuck check.
            warn "    IRQ $irq ($dev_name): write did not stick (still '$after')."
        fi

        # Could not constrain the mask (managed IRQ, or write ignored). What
        # actually matters is where it RUNS: effective_affinity_list. If the
        # kernel already keeps it on host cores (e.g. via isolcpus=managed_irq),
        # it is fine; only the ones genuinely landing on a VM core are a problem.
        # These are not per-IRQ warnings (NVMe alone can be dozens) -- summarized
        # in aggregate below.
        eff=""
        if [[ -r "$path/effective_affinity_list" ]]; then eff=$(<"$path/effective_affinity_list"); fi
        if [[ -n "$eff" ]] && ! irq_mask_hits_vm_core "$eff"; then
            managed_ok=$((managed_ok + 1))
        else
            stuck=$((stuck + 1))
            bn=${dev_name%%q[0-9]*}                                  # nvme1q25 -> nvme1
            stuck_by_dev["$bn"]=$(( ${stuck_by_dev["$bn"]:-0} + 1 ))
        fi
    done

    # --- Summary. Managed IRQs that cannot be steered are reported in aggregate,
    #     not one alarming line each. ---
    local verb="moved"
    if [[ $DRY_RUN -eq 1 ]]; then verb="to move"; fi
    local extra=""
    if [[ $managed_ok -gt 0 ]]; then extra=" (incl. $managed_ok managed, kernel-steered)"; fi
    log "  IRQ confinement: $moved $verb, $((skipped + managed_ok)) already on host cores${extra}, $stuck not steerable (of $considered device IRQs)."
    if [[ $stuck -gt 0 ]]; then
        local breakdown=""
        for bn in "${!stuck_by_dev[@]}"; do breakdown+="${bn} (${stuck_by_dev[$bn]}), "; done
        breakdown=${breakdown%, }
        warn "    $stuck managed IRQ(s) effectively on VM cores, not steerable at runtime: ${breakdown}."
        warn "    These rely on boot-time isolation (isolcpus=managed_irq, already in GRUB); queues whose"
        warn "    affinity mask is entirely VM cores cannot be relocated even then (inherent kernel limit)."
    fi
    return 0
}

if [[ "$RESERVE_HOST_CORES" == "true" ]]; then
    if [[ "$HOST_CORES_JSON" != "[]" && "$HOST_CORES_JSON" != "null" ]]; then
        while IFS= read -r core_id; do
            # A config copied from another machine (or a typo) must fail here,
            # not halfway through a systemctl call.
            if [[ ! "$core_id" =~ ^[0-9]+$ ]] || [[ ! -v CPU_TO_NODE["$core_id"] ]]; then
                error "host_cores entry '$core_id' is not a CPU on this host (valid: 0-$SMT_END)."
            fi
            CORES_TO_RESERVE+=("$core_id"); CORES_TO_RESERVE_MAP["$core_id"]=1
        done < <(echo "$HOST_CORES_JSON" | jq -r '.[]')
    else
        for socket_id in "${!SOCKET_IDS[@]}"; do
            min_core_id=${MIN_CORE_PER_SOCKET["$socket_id"]}
            for cpu_id in $(seq 0 $SMT_END); do
                if [[ "${CPU_TO_SOCKET[$cpu_id]}" == "$socket_id" && "${CPU_TO_CORE[$cpu_id]}" == "$min_core_id" ]]; then
                    CORES_TO_RESERVE+=("$cpu_id"); CORES_TO_RESERVE_MAP["$cpu_id"]=1
                fi
            done
        done
    fi

    if [[ ${#CORES_TO_RESERVE[@]} -gt 0 && $CONFINE_IRQS_ONLY -eq 0 ]]; then
        log "Host core reservation: ${CORES_TO_RESERVE[*]} (host pinning is applied only after the VM plan validates)."
    fi
fi

# -i: re-apply IRQ confinement only (e.g. from the boot-time systemd unit --
# /proc/irq affinity does not survive reboots) and skip the GPU/VM phases.
if [[ $CONFINE_IRQS_ONLY -eq 1 ]]; then
    log "--- IRQ confinement only (-i) ---"
    if [[ "$RESERVE_HOST_CORES" != "true" || ${#CORES_TO_RESERVE[@]} -eq 0 ]]; then
        error "-i requires reserve_host_cores=true and host_cores (or -a/-b) in the config."
    fi
    confine_device_irqs
    log "Script finished."
    exit 0
fi

# Apply host core pinning (systemd slices, GRUB params, IRQ confinement).
# Called AFTER planning succeeds: previously this ran during Phase 1, so a
# typo'd VMID or an infeasible plan aborted the run with the host already
# half-reconfigured.
apply_host_pinning() {
    if [[ "$RESERVE_HOST_CORES" != "true" || ${#CORES_TO_RESERVE[@]} -eq 0 ]]; then return 0; fi
    {
        host_cores_string=$(IFS=' '; echo "${CORES_TO_RESERVE[*]}")

        # Build the inverse set (all non-reserved cores) for the VM slice
        vm_cores_list=()
        for cpu_id in $(seq 0 $SMT_END); do
            if [[ ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
                vm_cores_list+=("$cpu_id")
            fi
        done

        vm_cores_ranges=""
        if (( ${#vm_cores_list[@]} > 0 )); then
            vm_cores_ranges=$(cpus_to_ranges "${vm_cores_list[@]}")
        else
            warn "Reserved host cores cover every CPU; no cores remain for VMs. Skipping qemu.slice/GRUB isolation."
        fi

        if [[ $DRY_RUN -eq 0 ]]; then
            log "Applying host core pinning..."

            # 1. AllowedCPUs via systemctl set-property
            log "  Setting AllowedCPUs on system.slice, user.slice, init.scope..."
            systemctl set-property system.slice AllowedCPUs="$host_cores_string"
            systemctl set-property user.slice AllowedCPUs="$host_cores_string"
            systemctl set-property init.scope AllowedCPUs="$host_cores_string"

            # 2. CPUAffinity drop-in for PID 1 (systemd manager)
            log "  Writing ${SYSTEMD_ETC}/system.conf.d/99-host-cores.conf..."
            mkdir -p "${SYSTEMD_ETC}/system.conf.d"
            cat > "${SYSTEMD_ETC}/system.conf.d/99-host-cores.conf" << EOF
[Manager]
CPUAffinity=$host_cores_string
EOF

            # 3. AllowedCPUs drop-in for qemu.slice (pin VMs to non-host cores).
            # Proxmox runs QEMU guests in qemu.slice (machine.slice is libvirt's
            # convention), and CPUAffinity= is a systemd *exec* directive that is
            # invalid in [Slice] sections -- the previous machine.slice drop-in
            # was silently ignored by systemd on both counts. AllowedCPUs= is the
            # cpuset-based directive slices actually support, and it also keeps
            # VMs that are NOT in the config off the reserved host cores.
            if [[ -n "$vm_cores_ranges" ]]; then
                log "  Writing ${SYSTEMD_ETC}/system/qemu.slice.d/99-vm-cores.conf..."
                mkdir -p "${SYSTEMD_ETC}/system/qemu.slice.d"
                cat > "${SYSTEMD_ETC}/system/qemu.slice.d/99-vm-cores.conf" << EOF
[Slice]
AllowedCPUs=$vm_cores_ranges
EOF
            fi

            # Migration: remove the obsolete (inert) machine.slice drop-in.
            if [[ -f "${SYSTEMD_ETC}/system/machine.slice.d/99-vm-cores.conf" ]]; then
                log "  Removing obsolete machine.slice drop-in (CPUAffinity= is not valid for slices)..."
                rm -f "${SYSTEMD_ETC}/system/machine.slice.d/99-vm-cores.conf"
            fi

            # 4. Reload systemd to pick up the drop-in files
            log "  Reloading systemd (daemon-reexec)..."
            systemctl daemon-reexec

            # Drop-ins affect qemu.slice when it is (re)loaded; if VMs are
            # already running the slice is live, so apply the cpuset now too.
            # --runtime keeps the drop-in above as the single persistent source.
            if [[ -n "$vm_cores_ranges" ]] && systemctl is-active --quiet qemu.slice 2>/dev/null; then
                log "  qemu.slice is active; applying AllowedCPUs to the live slice..."
                systemctl set-property --runtime qemu.slice AllowedCPUs="$vm_cores_ranges"
            fi

            log "Host core pinning applied successfully."
        else
            log "[DRY RUN] Host core pinning commands:"
            echo ""
            echo "  # AllowedCPUs on slices"
            echo "  systemctl set-property system.slice AllowedCPUs=\"$host_cores_string\""
            echo "  systemctl set-property user.slice AllowedCPUs=\"$host_cores_string\""
            echo "  systemctl set-property init.scope AllowedCPUs=\"$host_cores_string\""
            echo ""
            echo "  # CPUAffinity drop-in for PID 1 (systemd manager)"
            echo "  mkdir -p ${SYSTEMD_ETC}/system.conf.d"
            echo "  cat > ${SYSTEMD_ETC}/system.conf.d/99-host-cores.conf << EOF"
            echo "  [Manager]"
            echo "  CPUAffinity=$host_cores_string"
            echo "  EOF"
            echo ""
            if [[ -n "$vm_cores_ranges" ]]; then
                echo "  # AllowedCPUs drop-in for qemu.slice (pin VMs to non-host cores)"
                echo "  mkdir -p ${SYSTEMD_ETC}/system/qemu.slice.d"
                echo "  cat > ${SYSTEMD_ETC}/system/qemu.slice.d/99-vm-cores.conf << EOF"
                echo "  [Slice]"
                echo "  AllowedCPUs=$vm_cores_ranges"
                echo "  EOF"
                echo ""
            fi
            echo "  # Reload systemd"
            echo "  systemctl daemon-reexec"
            echo ""
        fi

        # --- GRUB kernel isolation parameters ---
        # Append a kernel param to $updated_line, respecting whichever quote
        # style the existing GRUB_CMDLINE_LINUX_DEFAULT line uses. (The old code
        # assumed a trailing double quote; on single-quoted or unquoted lines it
        # appended a stray '"' and corrupted /etc/default/grub.)
        grub_append_param() {
            local param=$1
            case "$updated_line" in
                *\") updated_line="${updated_line%\"} ${param}\"" ;;
                *\') updated_line="${updated_line%\'} ${param}'" ;;
                *)
                    local val=${updated_line#GRUB_CMDLINE_LINUX_DEFAULT=}
                    updated_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${val:+$val }${param}\""
                    ;;
            esac
        }

        if [[ -n "$vm_cores_ranges" ]]; then
        # Build the three kernel params
        isolcpus_val="managed_irq,domain,${vm_cores_ranges}"
        nohz_val="${vm_cores_ranges}"
        rcu_val="${vm_cores_ranges}"

        grub_file="$GRUB_FILE"
        if [[ -f "$grub_file" ]]; then
            current_line=$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" || true)
            current_isolcpus=$(echo "$current_line" | grep -oP "isolcpus=[^\s\"']+" || true)
            current_nohz=$(echo "$current_line" | grep -oP "nohz_full=[^\s\"']+" || true)
            current_rcu=$(echo "$current_line" | grep -oP "rcu_nocbs=[^\s\"']+" || true)

            new_isolcpus="isolcpus=${isolcpus_val}"
            new_nohz="nohz_full=${nohz_val}"
            new_rcu="rcu_nocbs=${rcu_val}"

            needs_update=false
            if [[ "$current_isolcpus" != "$new_isolcpus" || "$current_nohz" != "$new_nohz" || "$current_rcu" != "$new_rcu" ]]; then
                needs_update=true
            fi

            if [[ "$needs_update" == "true" ]]; then
                # Build updated line: replace existing params or append
                if [[ -n "$current_line" ]]; then
                    updated_line="$current_line"
                    if [[ -n "$current_isolcpus" ]]; then
                        updated_line="${updated_line//$current_isolcpus/$new_isolcpus}"
                    else
                        grub_append_param "$new_isolcpus"
                    fi
                    if [[ -n "$current_nohz" ]]; then
                        updated_line="${updated_line//$current_nohz/$new_nohz}"
                    else
                        grub_append_param "$new_nohz"
                    fi
                    if [[ -n "$current_rcu" ]]; then
                        updated_line="${updated_line//$current_rcu/$new_rcu}"
                    else
                        grub_append_param "$new_rcu"
                    fi
                else
                    updated_line="GRUB_CMDLINE_LINUX_DEFAULT=\"${new_isolcpus} ${new_nohz} ${new_rcu}\""
                fi

                if [[ $DRY_RUN -eq 0 ]]; then
                    log "Updating GRUB kernel isolation parameters..."
                    cp "$grub_file" "${grub_file}.backup.$(date +%Y%m%d_%H%M%S)"
                    if [[ -n "$current_line" ]]; then
                        # Escape sed replacement metacharacters so an unusual
                        # cmdline can't break the substitution.
                        sed_replacement=${updated_line//\\/\\\\}
                        sed_replacement=${sed_replacement//&/\\&}
                        sed_replacement=${sed_replacement//|/\\|}
                        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|${sed_replacement}|" "$grub_file"
                    else
                        echo "$updated_line" >> "$grub_file"
                    fi
                    log "  Updated $grub_file"
                    log "  Run 'update-grub' and reboot for changes to take effect."
                else
                    log "[DRY RUN] GRUB isolation parameters need updating:"
                    echo ""
                    echo "  # Current:"
                    echo "  $current_isolcpus $current_nohz $current_rcu"
                    echo ""
                    echo "  # New:"
                    echo "  $new_isolcpus $new_nohz $new_rcu"
                    echo ""
                fi
            else
                log "GRUB isolation parameters already correct."
            fi
        else
            warn "GRUB config $grub_file not found, skipping kernel param update."
        fi
        fi

        # IRQs are host work: steer movable device IRQs off VM cores onto the
        # reserved host cores at RUNTIME, complementing the boot-time
        # isolcpus=managed_irq/nohz_full/rcu_nocbs GRUB params set above.
        # CAVEAT: /proc/irq affinity is NOT persistent across reboot or NIC
        # driver/link reset -- run with -i after such events (or enable
        # extras/affinity-manager-irq.service). (The systemd drop-ins and GRUB
        # params above persist; this placement does not.)
        confine_device_irqs

        apply_host_tuning
    }
}

# --- OPT-IN HOST TUNING (tuning_settings) ---
# Pinning gets most of the way; these close the remaining host-side gaps.
# All default OFF because they change host-global behavior:
#   disable_numa_balancing: automatic NUMA balancing migrates tasks/pages to
#     chase locality -- with statically bound VMs it only adds scan overhead
#     and fights the explicit placement.
#   disable_ksm: KSM cannot merge hugetlbfs-backed guests at all, so on a
#     1G-hugepage host ksmd/ksmtuned is pure CPU overhead on the host cores.
#   cpu_governor: cpufreq governor for the VM cores (e.g. "performance").
apply_host_tuning() {
    local disable_numab disable_ksm governor
    disable_numab=$(jq -r '.tuning_settings.disable_numa_balancing // false' "$CONFIG_FILE")
    disable_ksm=$(jq -r '.tuning_settings.disable_ksm // false' "$CONFIG_FILE")
    governor=$(jq -r '.tuning_settings.cpu_governor // empty' "$CONFIG_FILE")

    if [[ "$disable_numab" != "true" && "$disable_ksm" != "true" && -z "$governor" ]]; then
        return 0
    fi
    log "Applying opt-in host tuning (tuning_settings)..."

    local numab_file="${PROC_SYS_BASE}/kernel/numa_balancing"
    if [[ "$disable_numab" == "true" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "  [DRY RUN] Would disable automatic NUMA balancing (kernel.numa_balancing=0, persisted in ${SYSCTL_D}/99-affinity-manager.conf)."
        elif [[ -f "$numab_file" ]]; then
            if echo 0 > "$numab_file" 2>/dev/null; then
                mkdir -p "$SYSCTL_D"
                printf 'kernel.numa_balancing = 0\n' > "${SYSCTL_D}/99-affinity-manager.conf"
                log "  Automatic NUMA balancing disabled (persisted: ${SYSCTL_D}/99-affinity-manager.conf)."
            else
                warn "  Could not write $numab_file."
            fi
        else
            log "  NUMA balancing knob not present ($numab_file); nothing to do."
        fi
    fi

    if [[ "$disable_ksm" == "true" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "  [DRY RUN] Would stop KSM (systemctl disable --now ksmtuned; echo 2 > $KSM_RUN_FILE)."
        else
            systemctl disable --now ksmtuned 2>/dev/null || true
            # 2 = stop ksmd AND unmerge all currently shared pages.
            if [[ -f "$KSM_RUN_FILE" ]]; then
                echo 2 > "$KSM_RUN_FILE" 2>/dev/null || true
            fi
            log "  KSM disabled (ksmtuned off, shared pages unmerged)."
        fi
    fi

    if [[ -n "$governor" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "  [DRY RUN] Would set cpufreq governor '$governor' on ${#vm_cores_list[@]} VM core(s)."
        else
            local cpu gov_file set_count=0
            for cpu in "${vm_cores_list[@]}"; do
                gov_file="${CPUFREQ_BASE}/cpu${cpu}/cpufreq/scaling_governor"
                if [[ -f "$gov_file" ]] && echo "$governor" > "$gov_file" 2>/dev/null; then
                    set_count=$((set_count + 1))
                fi
            done
            log "  cpufreq governor '$governor' set on ${set_count}/${#vm_cores_list[@]} VM core(s)."
            if (( set_count == 0 )); then
                warn "  No core accepted governor '$governor' (no cpufreq support, or invalid governor)."
            fi
        fi
    fi
}

declare -A AVAILABLE_PHYS_CORES AVAILABLE_SMT_CORES
for node_id in "${NUMA_NODE_IDS[@]}"; do
    AVAILABLE_PHYS_CORES["$node_id"]=""; AVAILABLE_SMT_CORES["$node_id"]=""
done
for cpu_id in $(seq 0 "$SMT_END"); do
    if [[ -v CPU_TO_NODE["$cpu_id"] && ! -v CORES_TO_RESERVE_MAP["$cpu_id"] ]]; then
        if [[ "${CPU_IS_SMT[$cpu_id]:-0}" == "0" ]]; then
            AVAILABLE_PHYS_CORES["${CPU_TO_NODE[$cpu_id]}"]+="$cpu_id "
        else
            AVAILABLE_SMT_CORES["${CPU_TO_NODE[$cpu_id]}"]+="$cpu_id "
        fi
    fi
done


# =============================================================================
# --- PHASE 1.5: GPU TOPOLOGY & VRAM CAPACITY CHECK ---
# =============================================================================
log "--- PHASE 1.5: Discovering GPUs and MDEV Capacities ---"

declare -A GPU_MAP GPU_MDEV_PROFILE GPU_SLOTS_FREE GPU_SLOTS_REUSABLE GPU_SLOTS_CAP
declare -a GPU_PCI_IDS

if [[ $SKIP_GPU -eq 1 ]]; then
    log "  GPU assignment skipped (-g flag set)."
fi

# Probe one GPU (sysfs + nvidia-smi) and, on success, write a single
# "pci|node|profile|slots|cap" line to $datfile. Designed to run as a background
# job; emits its own log/warn lines (captured and replayed in order by the
# parent) and touches no shared arrays.
discover_one_gpu() {
    local pci_slot=$1
    local datfile=$2
    local target_vram=$3
    local auto_detect=$4
    local manual_mdev=$5

    local numa_path="${PCI_SYS_BASE}/${pci_slot}/numa_node"
    local numa_node="0"
    if [[ -f "$numa_path" ]]; then
        val=$(cat "$numa_path")
        if [[ "$val" != "-1" ]]; then numa_node=$val; fi
    fi

    local mdev_base="${PCI_SYS_BASE}/${pci_slot}/mdev_supported_types"
    local selected_type=""
    local available_instances=0

    if [[ -d "$mdev_base" ]]; then
        if [[ "$auto_detect" == "true" ]]; then
            for type_dir in $(ls -1v "$mdev_base"); do
                desc_file="${mdev_base}/${type_dir}/description"
                if [[ -f "$desc_file" ]]; then
                    if grep -q "framebuffer=${target_vram}M" "$desc_file"; then
                        selected_type="$type_dir"
                        available_instances=$(cat "${mdev_base}/${type_dir}/available_instances")
                        break
                    fi
                fi
            done
        else
            # Check for per-GPU profile mapping first
            local gpu_specific_mdev=$(jq -r --arg pci "$pci_slot" '.gpu_settings.gpu_profile_map[$pci] // empty' "$CONFIG_FILE")
            if [[ -n "$gpu_specific_mdev" && -d "${mdev_base}/${gpu_specific_mdev}" ]]; then
                selected_type="$gpu_specific_mdev"
                available_instances=$(cat "${mdev_base}/${gpu_specific_mdev}/available_instances")
                log "    Using per-GPU profile mapping: $gpu_specific_mdev"
            elif [[ -d "${mdev_base}/${manual_mdev}" ]]; then
                selected_type="$manual_mdev"
                available_instances=$(cat "${mdev_base}/${manual_mdev}/available_instances")
            fi
        fi
    else
        log "  GPU $pci_slot: No MDEV support found."
        return 0
    fi

    if [[ -n "$selected_type" && $available_instances -gt 0 ]]; then
        local vram_slot_cap=0
        if command -v nvidia-smi &> /dev/null; then
            local total_mem_mb=$(nvidia-smi --id="$pci_slot" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "0")
            if [[ "$total_mem_mb" -gt 0 ]]; then
                local calculated_slots=$(( total_mem_mb / target_vram ))
                vram_slot_cap=$calculated_slots
                if (( calculated_slots < available_instances )); then
                    log "  [Override] GPU $pci_slot: Sysfs reports $available_instances slots, but VRAM ($total_mem_mb MB) limits to $calculated_slots."
                    available_instances=$calculated_slots
                fi
            fi
        fi

        if (( available_instances > 0 )); then
            local slot_cap=$available_instances
            if (( vram_slot_cap > 0 )); then slot_cap=$vram_slot_cap; fi
            printf '%s|%s|%s|%s|%s\n' "$pci_slot" "$numa_node" "$selected_type" "$available_instances" "$slot_cap" > "$datfile"
            log "  Registered GPU $pci_slot: Profile $selected_type | Slots Available: $available_instances | Node: $numa_node"
        else
            warn "  GPU $pci_slot ignored: $selected_type valid, but 0 slots available after VRAM check."
        fi
    fi
}

discover_gpus() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi
    local target_vram=$(jq -r '.gpu_settings.required_vram_mb // 2048' "$CONFIG_FILE")
    local auto_detect=$(jq -r 'if .gpu_settings.auto_detect_profile == false then "false" else "true" end' "$CONFIG_FILE")
    local manual_mdev=$(jq -r '.gpu_settings.mdev_override // "nvidia-47"' "$CONFIG_FILE")

    log "  GPU Strategy: VRAM=${target_vram}MB, AutoDetect=${auto_detect}"

    # Build lspci input: use gpu_pci_ids override if provided, otherwise auto-detect
    local pci_override_count
    pci_override_count=$(jq -r '(.gpu_settings.gpu_pci_ids // []) | length' "$CONFIG_FILE")

    local lspci_input
    if (( pci_override_count > 0 )); then
        log "  Using config gpu_pci_ids override ($pci_override_count GPU(s) specified)"
        # Fake lspci lines: just the PCI slot — the loop only uses field 1
        lspci_input=$(jq -r '(.gpu_settings.gpu_pci_ids // [])[]' "$CONFIG_FILE")
    else
        # `|| true`: with zero NVIDIA devices the grep pipeline returns nonzero,
        # which under set -e used to kill the whole script silently right here.
        lspci_input=$(lspci -D -nn | grep -E "\[03[0-9a-fA-F]{2}\]" | grep -i nvidia || true)
        if [[ -z "$lspci_input" ]]; then
            warn "  No NVIDIA display-class devices found via lspci. Check lspci output or set gpu_settings.gpu_pci_ids in config."
        fi
    fi

    # Parse candidate PCI slots up front so the progress total is exact.
    local -a gpu_slots=()
    local line pci_slot
    while read -r line; do
        [[ -n "$line" ]] || continue
        pci_slot=$(echo "$line" | cut -d ' ' -f 1)
        [[ -n "$pci_slot" ]] || continue
        gpu_slots+=("$pci_slot")
    done < <(echo "$lspci_input")

    # Probe every GPU in parallel: each is an independent sysfs + nvidia-smi read.
    local _gtmp; _gtmp=$(mktemp -d)
    parallel_begin "GPU probing" "${#gpu_slots[@]}"
    for pci_slot in "${gpu_slots[@]}"; do
        parallel_throttle
        { discover_one_gpu "$pci_slot" "$_gtmp/${pci_slot}.dat" "$target_vram" "$auto_detect" "$manual_mdev" > "$_gtmp/${pci_slot}.log" 2>&1; } &
        parallel_track "GPU $pci_slot" $!
    done
    parallel_drain

    # Replay captured logs, then fold the results back into the global arrays in a
    # stable (PCI-sorted) order so planning is deterministic regardless of timing.
    local f
    for f in $(find "$_gtmp" -name '*.log' 2>/dev/null | sort); do
        replay_captured "$f"
    done
    for f in $(find "$_gtmp" -name '*.dat' 2>/dev/null | sort); do
        local pci numa_node selected_type available_instances slot_cap
        IFS='|' read -r pci numa_node selected_type available_instances slot_cap < "$f"
        [[ -n "$pci" ]] || continue
        GPU_PCI_IDS+=("$pci")
        GPU_MAP["$pci"]=$numa_node
        GPU_MDEV_PROFILE["$pci"]=$selected_type
        GPU_SLOTS_FREE["$pci"]=$available_instances
        GPU_SLOTS_CAP["$pci"]=$slot_cap
    done
    rm -rf "$_gtmp"
}

discover_gpus


# =============================================================================
# --- PHASE 2: READ CONFIG ---
# =============================================================================
log "--- PHASE 2: Reading VM Configurations ---"
declare -A VMS_TO_CONFIGURE VM_DISK_NODE_PREFERENCE VM_DISK_NODE_SOURCE
declare -A VM_MEMORY_MB VM_HUGEPAGE_1G_PAGES
declare -A NODE_1G_HUGEPAGES_TOTAL NODE_1G_HUGEPAGES_PLANNED NODE_1G_HUGEPAGES_FREE
TOTAL_CORES_REQUESTED=0

HUGEPAGE_NODE_SAFETY_PAGES=$(jq -r '.global_settings.hugepage_node_safety_pages // 2' "$CONFIG_FILE")
if [[ ! "$HUGEPAGE_NODE_SAFETY_PAGES" =~ ^[0-9]+$ ]]; then
    HUGEPAGE_NODE_SAFETY_PAGES=2
fi
log "  Hugepage node safety margin: ${HUGEPAGE_NODE_SAFETY_PAGES} x 1G page(s)."

for node_id in "${NUMA_NODE_IDS[@]}"; do
    hp_dir="${NODE_SYS_BASE}/node${node_id}/hugepages/hugepages-1048576kB"
    NODE_1G_HUGEPAGES_PLANNED["$node_id"]=0
    NODE_1G_HUGEPAGES_TOTAL["$node_id"]=-1
    NODE_1G_HUGEPAGES_FREE["$node_id"]=-1
    if [[ -f "$hp_dir/nr_hugepages" ]]; then
        hp_total=$(cat "$hp_dir/nr_hugepages" 2>/dev/null || echo "-1")
        if [[ "$hp_total" =~ ^[0-9]+$ ]]; then
            NODE_1G_HUGEPAGES_TOTAL["$node_id"]=$hp_total
        fi
    fi
    # Free pages matter too: nr_hugepages counts pages already consumed by
    # running VMs (including ones outside this config), which the planner
    # cannot reclaim.
    if [[ -f "$hp_dir/free_hugepages" ]]; then
        hp_free=$(cat "$hp_dir/free_hugepages" 2>/dev/null || echo "-1")
        if [[ "$hp_free" =~ ^[0-9]+$ ]]; then
            NODE_1G_HUGEPAGES_FREE["$node_id"]=$hp_free
        fi
    fi
done

# Cheap serial pass: VM core counts and the running total come straight from the
# config (jq), no per-VM subprocess latency, and the total must accumulate in order.
for vmid in $(jq -r '.vms | keys[]' "$CONFIG_FILE"); do
    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        error "Invalid VM ID '$vmid' in config (must be numeric)."
    fi
    cores=$(jq -r --arg vmid "$vmid" '.vms[$vmid]' "$CONFIG_FILE")
    if [[ ! "$cores" =~ ^[0-9]+$ ]] || (( cores < 1 )); then
        error "VM $vmid: invalid core count '$cores' in config (must be a positive integer)."
    fi
    VMS_TO_CONFIGURE["$vmid"]="$cores"
    TOTAL_CORES_REQUESTED=$((TOTAL_CORES_REQUESTED + cores))
done
if (( ${#VMS_TO_CONFIGURE[@]} == 0 )); then
    error "No VMs defined in config (.vms is empty)."
fi

# Parallel pass: per-VM memory read (qm config) and disk-locality detection are
# latency-bound (qm/pvesm/lsblk/lvs/vgs) and fully independent across VMs. Each
# job writes "mem_mb|pages|mem_ok|disk_node|disk_source" to a temp file.
_p2_tmp=$(mktemp -d)
parallel_begin "Disk/memory detection" "${#VMS_TO_CONFIGURE[@]}"
for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
    parallel_throttle
    {
        # Existence first: a typo'd VMID must abort the run before anything is
        # mutated, not surface as a pile of qm errors at the very end.
        vm_exists=0
        if qm config "$vmid" > /dev/null 2>&1; then vm_exists=1; fi

        vm_mem_mb=$(qm config "$vmid" 2>/dev/null | awk '/^memory:/ {print $2; exit}')
        if [[ "$vm_mem_mb" =~ ^[0-9]+$ ]] && (( vm_mem_mb > 0 )); then
            mem_ok=1
            vm_pages_1g=$(( (vm_mem_mb + 1023) / 1024 ))
        else
            mem_ok=0
            vm_mem_mb=0
            vm_pages_1g=0
        fi

        disk_pref_info=$(detect_vm_disk_preference "$vmid" || true)
        disk_node=""
        disk_source=""
        if [[ -n "$disk_pref_info" ]]; then
            IFS='|' read -r disk_node disk_source <<< "$disk_pref_info"
        fi

        printf '%s|%s|%s|%s|%s|%s\n' "$vm_exists" "$vm_mem_mb" "$vm_pages_1g" "$mem_ok" "$disk_node" "$disk_source" > "$_p2_tmp/$vmid"
    } &
    parallel_track "VM $vmid" $!
done
parallel_drain

# Collect results back into the global arrays in sorted order (logs stay readable
# and ordered exactly as in the sequential version).
_missing_vms=()
for vmid in $(printf '%s\n' "${!VMS_TO_CONFIGURE[@]}" | sort -n); do
    cores=${VMS_TO_CONFIGURE[$vmid]}
    if [[ -f "$_p2_tmp/$vmid" ]]; then
        IFS='|' read -r vm_exists vm_mem_mb vm_pages_1g mem_ok disk_node disk_source < "$_p2_tmp/$vmid"
    else
        vm_exists=0; vm_mem_mb=0; vm_pages_1g=0; mem_ok=0; disk_node=""; disk_source=""
    fi

    if [[ "$vm_exists" != "1" ]]; then
        _missing_vms+=("$vmid")
        continue
    fi

    VM_MEMORY_MB["$vmid"]=${vm_mem_mb:-0}
    VM_HUGEPAGE_1G_PAGES["$vmid"]=${vm_pages_1g:-0}
    if [[ "$mem_ok" != "1" ]]; then
        warn "  VM $vmid: could not read memory size for hugepage planning; hugepage guard skipped for this VM."
    fi

    if [[ -n "$disk_node" ]]; then
        VM_DISK_NODE_PREFERENCE["$vmid"]="$disk_node"
        VM_DISK_NODE_SOURCE["$vmid"]="$disk_source"
        log "  VM $vmid: $cores cores$([ $SKIP_GPU -eq 1 ] && echo '' || echo ' [GPU TARGET]') [Disk prefers Node $disk_node via $disk_source]"
    else
        log "  VM $vmid: $cores cores$([ $SKIP_GPU -eq 1 ] && echo '' || echo ' [GPU TARGET]') [Disk preference: none detected]"
    fi
done
rm -rf "$_p2_tmp"

if (( ${#_missing_vms[@]} > 0 )); then
    error "VM(s) not found on this node: ${_missing_vms[*]}. No changes were applied."
fi

adjust_gpu_slots_for_running_vms() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi

    local vmid vm_status hostpci_line current_pci current_mdev expected_mdev reused_count
    local base_free effective_slots slot_cap effective_reused
    local adjusted_any=false
    declare -A running_vm_gpu_counts

    for current_pci in "${GPU_PCI_IDS[@]}"; do
        running_vm_gpu_counts["$current_pci"]=0
        GPU_SLOTS_REUSABLE["$current_pci"]=0
    done

    for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)
        [[ "$vm_status" == "running" ]] || continue

        hostpci_line=$(qm config "$vmid" 2>/dev/null | sed -n 's/^hostpci0: //p' | head -n1)
        [[ -n "$hostpci_line" ]] || continue

        current_pci=$(echo "$hostpci_line" | cut -d',' -f1)
        [[ -v GPU_SLOTS_FREE["$current_pci"] ]] || continue

        current_mdev=$(echo "$hostpci_line" | sed -n 's/.*mdev=\([^,]*\).*/\1/p')
        expected_mdev=${GPU_MDEV_PROFILE["$current_pci"]:-}

        # Only reclaim slots from running VMs that already use the profile we plan to assign.
        if [[ -n "$expected_mdev" && -n "$current_mdev" && "$current_mdev" != "$expected_mdev" ]]; then
            continue
        fi

        running_vm_gpu_counts["$current_pci"]=$(( ${running_vm_gpu_counts[$current_pci]:-0} + 1 ))
    done

    for current_pci in "${GPU_PCI_IDS[@]}"; do
        reused_count=${running_vm_gpu_counts[$current_pci]:-0}
        base_free=${GPU_SLOTS_FREE[$current_pci]:-0}
        slot_cap=${GPU_SLOTS_CAP[$current_pci]:-0}
        effective_slots=$(( base_free + reused_count ))

        # Guardrail: never let planning exceed this GPU's capacity.
        if (( slot_cap > 0 && effective_slots > slot_cap )); then
            log "  Capping planning capacity on GPU $current_pci: requested ${effective_slots} slot(s) (free=${base_free} + reusable=${reused_count}), cap=${slot_cap}."
            effective_slots=$slot_cap
        fi

        effective_reused=$(( effective_slots - base_free ))
        if (( effective_reused < 0 )); then
            effective_reused=0
        fi

        GPU_SLOTS_REUSABLE["$current_pci"]=$effective_reused
        GPU_SLOTS_FREE["$current_pci"]=$effective_slots

        if (( reused_count > 0 )); then
            adjusted_any=true
            log "  Planning capacity: GPU $current_pci reuses $effective_reused running slot(s) from listed VMs."
        fi
    done

    if [[ "$adjusted_any" == true ]]; then
        log "  Effective GPU slot counts were adjusted to include reusable running assignments."
    fi
}

adjust_gpu_slots_for_running_vms

node_hugepage_fits() {
    local node_id=$1
    local vmid=$2
    local use_safety_margin=$3
    local total_pages=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
    local planned_pages=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
    local vm_pages=${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}
    local limit_pages

    if (( total_pages < 0 || vm_pages <= 0 )); then
        return 0
    fi

    limit_pages=$total_pages
    if [[ "$use_safety_margin" == "true" ]]; then
        limit_pages=$(( total_pages - HUGEPAGE_NODE_SAFETY_PAGES ))
        if (( limit_pages < 0 )); then
            limit_pages=0
        fi
    fi

    (( planned_pages + vm_pages <= limit_pages ))
}

preflight_gpu_cpu_feasibility() {
    if [[ $SKIP_GPU -eq 1 ]]; then return; fi

    local total_gpu_vms=${#VMS_TO_CONFIGURE[@]}
    local -A unique_vm_core_counts=()
    local -A unique_vm_page_counts=()
    local vmid vm_cores
    for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
        vm_cores=${VMS_TO_CONFIGURE[$vmid]}
        unique_vm_core_counts["$vm_cores"]=1
        unique_vm_page_counts["${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}"]=1
    done

    # Exact early feasibility is only straightforward when all GPU VMs use one core count.
    if (( ${#unique_vm_core_counts[@]} != 1 )); then
        warn "Skipping exact pre-flight GPU/CPU feasibility check: mixed VM core counts detected."
        return
    fi

    local per_vm_cores
    for per_vm_cores in "${!unique_vm_core_counts[@]}"; do :; done

    local per_vm_pages=0
    local strict_hugepage_check=true
    if (( ${#unique_vm_page_counts[@]} == 1 )); then
        for per_vm_pages in "${!unique_vm_page_counts[@]}"; do :; done
    else
        strict_hugepage_check=false
        warn "Skipping exact pre-flight hugepage feasibility check: mixed VM memory sizes detected."
    fi

    local -A node_gpu_slots=()
    local pci node_id
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        node_gpu_slots["$node_id"]=0
    done

    for pci in "${GPU_PCI_IDS[@]}"; do
        node_id=${GPU_MAP[$pci]}
        node_gpu_slots["$node_id"]=$(( ${node_gpu_slots[$node_id]:-0} + ${GPU_SLOTS_FREE[$pci]:-0} ))
    done

    local total_pairable_vms=0
    local node_free_cores cores_limited_vms slot_limited_vms pairable_on_node
    local node_hugepages_total hugepage_limited_vms
    local avail_phys_list avail_smt_list
    local hugepage_context=""

    if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 ]]; then
        hugepage_context=" and ${per_vm_pages}x1G hugepages"
    fi

    log "--- PHASE 2.5: Pre-flight GPU/CPU Feasibility (Best Effort) ---"
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
        avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
        node_free_cores=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))

        cores_limited_vms=$(( node_free_cores / per_vm_cores ))
        slot_limited_vms=${node_gpu_slots[$node_id]:-0}
        pairable_on_node=$cores_limited_vms
        if (( slot_limited_vms < pairable_on_node )); then
            pairable_on_node=$slot_limited_vms
        fi

        node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
        hugepage_limited_vms=$pairable_on_node
        if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 && $node_hugepages_total -ge 0 ]]; then
            hugepage_limited_vms=$(( node_hugepages_total / per_vm_pages ))
            if (( hugepage_limited_vms < pairable_on_node )); then
                pairable_on_node=$hugepage_limited_vms
            fi
        fi

        total_pairable_vms=$(( total_pairable_vms + pairable_on_node ))
        if [[ "$strict_hugepage_check" == "true" && "$per_vm_pages" =~ ^[0-9]+$ && $per_vm_pages -gt 0 && $node_hugepages_total -ge 0 ]]; then
            log "  Node $node_id: free_cores=$node_free_cores, gpu_slots=${node_gpu_slots[$node_id]:-0}, hugepages_total=$node_hugepages_total, max_pairable_vms=$pairable_on_node"
        else
            log "  Node $node_id: free_cores=$node_free_cores, gpu_slots=${node_gpu_slots[$node_id]:-0}, max_pairable_vms=$pairable_on_node"
        fi
    done

    if (( total_pairable_vms < total_gpu_vms )); then
        shortfall=$(( total_gpu_vms - total_pairable_vms ))
        warn "Pre-flight note: requested $total_gpu_vms GPU-target VM(s), but topology can pair at most $total_pairable_vms VM(s) at ${per_vm_cores} cores each${hugepage_context}. Planner will continue in best-effort mode and place up to $shortfall VM(s) without GPU if CPU/hugepages allow."
        return
    fi

    log "  Pre-flight passed: requested $total_gpu_vms GPU VM(s), max pairable is $total_pairable_vms."
}

preflight_gpu_cpu_feasibility


# =============================================================================
# --- PHASE 3: PLANNING & ASSIGNMENT ---
# =============================================================================
log "--- PHASE 3: Planning Resources (Load Balanced) ---"
declare -A VM_ASSIGNMENTS CORES_ASSIGNED_PER_NODE
for node_id in "${NUMA_NODE_IDS[@]}"; do CORES_ASSIGNED_PER_NODE["$node_id"]=0; done

TOTAL_PHYS_AVAIL=0; for n in "${AVAILABLE_PHYS_CORES[@]}"; do TOTAL_PHYS_AVAIL=$((TOTAL_PHYS_AVAIL + $(echo $n | wc -w))); done
PHYSICAL_CORE_RATIO="1.0"
USE_SMT_CORES=false
if (( TOTAL_CORES_REQUESTED > TOTAL_PHYS_AVAIL )); then
    PHYSICAL_CORE_RATIO=$(echo "scale=4; $TOTAL_PHYS_AVAIL / $TOTAL_CORES_REQUESTED" | bc)
    USE_SMT_CORES=true
fi

sorted_vmids=$(for vmid in "${!VMS_TO_CONFIGURE[@]}"; do echo "${VMS_TO_CONFIGURE[$vmid]} $vmid"; done | sort -rn | awk '{print $2}')

GPU_FALLBACK_COUNT=0
declare -a GPU_FALLBACK_VMIDS

log_pairing_debug_state() {
    local vmid=$1
    local cpu_count=$2

    warn "Pairing debug for VM $vmid ($cpu_count cores required):"
    for node_id in "${NUMA_NODE_IDS[@]}"; do
        local avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
        local avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
        local total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))
        local node_gpu_slots=0
        local node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
        local node_hugepages_planned=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
        local node_hugepages_remaining="n/a"

        if (( node_hugepages_total >= 0 )); then
            node_hugepages_remaining=$(( node_hugepages_total - node_hugepages_planned ))
        fi

        for pci in "${GPU_PCI_IDS[@]}"; do
            if [[ "${GPU_MAP[$pci]}" == "$node_id" ]]; then
                node_gpu_slots=$(( node_gpu_slots + ${GPU_SLOTS_FREE[$pci]:-0} ))
            fi
        done

        warn "  Node $node_id: free_cores=$total_avail, free_gpu_slots=$node_gpu_slots, hugepages_planned=$node_hugepages_planned, hugepages_total=$node_hugepages_total, hugepages_remaining=$node_hugepages_remaining"
    done

    for pci in "${GPU_PCI_IDS[@]}"; do
        warn "  GPU $pci on Node ${GPU_MAP[$pci]}: slots_free=${GPU_SLOTS_FREE[$pci]:-0} (${GPU_MDEV_PROFILE[$pci]})"
    done
}

find_best_cpu_only_node() {
    local vmid=$1
    local cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    local preferred_disk_node=${VM_DISK_NODE_PREFERENCE[$vmid]:-}

    local best_node=""
    local best_hugepage_fit_score=-1
    local best_match_score=-1
    local max_free_cores=-1
    local node_id avail_phys_list avail_smt_list total_avail match_score hugepage_fit_score

    for node_id in "${NUMA_NODE_IDS[@]}"; do
        avail_phys_list=(${AVAILABLE_PHYS_CORES["$node_id"]:-})
        avail_smt_list=(${AVAILABLE_SMT_CORES["$node_id"]:-})
        total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))
        match_score=0
        hugepage_fit_score=1

        if [[ -n "$preferred_disk_node" && "$node_id" == "$preferred_disk_node" ]]; then
            match_score=1
        fi

        if (( cpu_count > total_avail )); then
            continue
        fi

        if ! node_hugepage_fits "$node_id" "$vmid" "false"; then
            continue
        fi
        if ! node_hugepage_fits "$node_id" "$vmid" "true"; then
            hugepage_fit_score=0
        fi

        if (( hugepage_fit_score > best_hugepage_fit_score \
            || (hugepage_fit_score == best_hugepage_fit_score && match_score > best_match_score) \
            || (hugepage_fit_score == best_hugepage_fit_score && match_score == best_match_score && total_avail > max_free_cores) )); then
            best_hugepage_fit_score=$hugepage_fit_score
            best_match_score=$match_score
            max_free_cores=$total_avail
            best_node=$node_id
        fi
    done

    if [[ -n "$best_node" ]]; then
        echo "$best_node|$max_free_cores"
        return 0
    fi

    return 1
}

assign_resources() {
    local vmid=$1
    local forced_node=$2
    local gpu_pci=$3
    local gpu_mdev=$4
    local cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    local vm_hugepage_pages=${VM_HUGEPAGE_1G_PAGES[$vmid]:-0}
    local disk_node_preference=${VM_DISK_NODE_PREFERENCE[$vmid]:-}
    local disk_source=${VM_DISK_NODE_SOURCE[$vmid]:-}
    local disk_match=false
    
    local target_node=$forced_node
    local avail_phys=(${AVAILABLE_PHYS_CORES["$target_node"]:-})
    local avail_smt=(${AVAILABLE_SMT_CORES["$target_node"]:-})

    if [[ -n "$disk_node_preference" && "$target_node" == "$disk_node_preference" ]]; then
        disk_match=true
    fi
    
    local phys_needed=$cpu_count
    local smt_needed=0

    if [[ "$USE_SMT_CORES" == true ]]; then
        phys_needed=$(echo "$cpu_count * $PHYSICAL_CORE_RATIO / 1" | bc)
    fi
    # Clamp to what the node actually has and take the remainder from SMT.
    # (Previously, with USE_SMT_CORES=false and a node short on physical cores,
    # the array slice came up short and the VM silently got FEWER cores than
    # configured.)
    if (( phys_needed > ${#avail_phys[@]} )); then phys_needed=${#avail_phys[@]}; fi
    smt_needed=$(( cpu_count - phys_needed ))
    if (( smt_needed < 0 )); then smt_needed=0; fi

    if (( (phys_needed + smt_needed) > (${#avail_phys[@]} + ${#avail_smt[@]}) )); then
        error "VM $vmid: Node $target_node has insufficient cores! (GPU Locked)"
    fi

    local node_hugepages_total=${NODE_1G_HUGEPAGES_TOTAL[$target_node]:--1}
    local node_hugepages_planned=${NODE_1G_HUGEPAGES_PLANNED[$target_node]:-0}
    if (( node_hugepages_total >= 0 && vm_hugepage_pages > 0 )); then
        if (( node_hugepages_planned + vm_hugepage_pages > node_hugepages_total )); then
            error "VM $vmid: Node $target_node has insufficient 1G hugepages! planned=${node_hugepages_planned}, needed=${vm_hugepage_pages}, total=${node_hugepages_total}"
        fi
    fi

    # Physical cores come off the front of the free list; SMT picks PREFER the
    # siblings of this VM's own physical cores, so both threads of a core stay
    # inside one VM. The old code took SMT threads in plain list order, which
    # only happened to align when every VM had the same size -- with mixed core
    # counts a VM could end up sharing a physical core's pipeline with a
    # different VM (cross-VM noisy neighbor).
    local assigned_phys=( "${avail_phys[@]:0:$phys_needed}" )
    local assigned_smt=()
    if (( smt_needed > 0 )); then
        local -A _own_siblings=()
        local _c _s
        for _c in "${assigned_phys[@]}"; do
            for _s in ${CPU_SIBLINGS[$_c]:-}; do _own_siblings["$_s"]=1; done
        done
        local -a _smt_pref=() _smt_rest=()
        for _s in "${avail_smt[@]}"; do
            if [[ -v _own_siblings["$_s"] ]]; then _smt_pref+=("$_s"); else _smt_rest+=("$_s"); fi
        done
        assigned_smt=( "${_smt_pref[@]:0:$smt_needed}" )
        if (( ${#assigned_smt[@]} < smt_needed )); then
            assigned_smt+=( "${_smt_rest[@]:0:$(( smt_needed - ${#assigned_smt[@]} ))}" )
        fi
    fi
    local assigned_cores=( "${assigned_phys[@]}" "${assigned_smt[@]}" )

    if (( ${#assigned_cores[@]} != cpu_count )); then
        error "VM $vmid: internal allocation error on Node $target_node (got ${#assigned_cores[@]} of $cpu_count cores)."
    fi

    # [FIX] Changed delimiter from ':' to '|' to handle PCI IDs correctly
    local plan="cores=$(IFS=,; echo "${assigned_cores[*]}")|node=${target_node}"
    if [[ -n "$gpu_pci" ]]; then plan="$plan|gpu_pci=${gpu_pci}|mdev=${gpu_mdev}"; fi
    if [[ -n "$disk_node_preference" ]]; then
        plan="$plan|disk_node=${disk_node_preference}|disk_source=${disk_source}|disk_match=${disk_match}"
    fi
    
    VM_ASSIGNMENTS["$vmid"]="$plan"
    CORES_ASSIGNED_PER_NODE["$target_node"]=$(( ${CORES_ASSIGNED_PER_NODE[$target_node]} + cpu_count ))
    NODE_1G_HUGEPAGES_PLANNED["$target_node"]=$(( ${NODE_1G_HUGEPAGES_PLANNED[$target_node]:-0} + vm_hugepage_pages ))
    
    for core in "${assigned_cores[@]}"; do
        AVAILABLE_PHYS_CORES["$target_node"]=$(echo "${AVAILABLE_PHYS_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
        AVAILABLE_SMT_CORES["$target_node"]=$(echo "${AVAILABLE_SMT_CORES[$target_node]}" | sed "s/\b${core}\b\s*//g")
    done
}

# --- MAIN ASSIGNMENT LOOP ---
for vmid in $sorted_vmids; do
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}
    preferred_disk_node=${VM_DISK_NODE_PREFERENCE[$vmid]:-}
    preferred_disk_source=${VM_DISK_NODE_SOURCE[$vmid]:-}
    best_pci=""
    best_hugepage_fit_score=-1
    best_match_score=-1
    max_free_cores=-1
    slot_and_core_candidates=0
    slot_core_hugepage_blocked=0

    # 1. SCAN for Best Candidate
    for pci in "${GPU_PCI_IDS[@]}"; do
        if [[ ${GPU_SLOTS_FREE[$pci]} -gt 0 ]]; then
            node=${GPU_MAP[$pci]}
            match_score=0
            hugepage_fit_score=1

            # Count free cores on this node (Global Vars used, NO LOCAL)
            avail_phys_list=(${AVAILABLE_PHYS_CORES["$node"]:-})
            avail_smt_list=(${AVAILABLE_SMT_CORES["$node"]:-})
            total_avail=$(( ${#avail_phys_list[@]} + ${#avail_smt_list[@]} ))

            if (( cpu_count > total_avail )); then
                continue
            fi

            slot_and_core_candidates=$(( slot_and_core_candidates + 1 ))

            if ! node_hugepage_fits "$node" "$vmid" "false"; then
                slot_core_hugepage_blocked=$(( slot_core_hugepage_blocked + 1 ))
                continue
            fi

            if [[ -n "$preferred_disk_node" && "$node" == "$preferred_disk_node" ]]; then
                match_score=1
            fi
            if ! node_hugepage_fits "$node" "$vmid" "true"; then
                hugepage_fit_score=0
            fi

            if (( hugepage_fit_score > best_hugepage_fit_score \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score > best_match_score) \
                || (hugepage_fit_score == best_hugepage_fit_score && match_score == best_match_score && total_avail > max_free_cores) )); then
                best_hugepage_fit_score=$hugepage_fit_score
                best_match_score=$match_score
                max_free_cores=$total_avail
                best_pci=$pci
            fi
        fi
    done

    # 2. ASSIGN if candidate found
    if [[ $SKIP_GPU -eq 1 ]]; then
        cpu_node_choice=$(find_best_cpu_only_node "$vmid" || true)
        if [[ -z "$cpu_node_choice" ]]; then
            error "VM $vmid: no NUMA node has enough free cores/hugepages!"
        fi
        IFS='|' read -r best_node max_free_cores <<< "$cpu_node_choice"
        if [[ -z "$best_node" ]]; then
            error "VM $vmid: no NUMA node has enough free cores/hugepages!"
        fi
        if [[ -n "$preferred_disk_node" ]]; then
            log "  Assigning VM $vmid to Node $best_node (disk prefers Node $preferred_disk_node via $preferred_disk_source, matched=$([ "$best_node" == "$preferred_disk_node" ] && echo yes || echo no), Node Free: $max_free_cores)"
        else
            log "  Assigning VM $vmid to Node $best_node (no GPU, disk preference=none, Node Free: $max_free_cores)"
        fi
        assign_resources "$vmid" "$best_node" "" ""
    elif [[ -n "$best_pci" ]]; then
        pci=$best_pci
        node=${GPU_MAP[$pci]}
        mdev=${GPU_MDEV_PROFILE[$pci]}

        if [[ -n "$preferred_disk_node" ]]; then
            log "  Assigning GPU $pci ($mdev) on Node $node to VM $vmid (disk prefers Node $preferred_disk_node via $preferred_disk_source, matched=$([ "$node" == "$preferred_disk_node" ] && echo yes || echo no), Node Free: $max_free_cores)"
        else
            log "  Assigning GPU $pci ($mdev) on Node $node to VM $vmid (disk preference=none, Node Free: $max_free_cores)"
        fi
        assign_resources "$vmid" "$node" "$pci" "$mdev"
        GPU_SLOTS_FREE[$pci]=$(( ${GPU_SLOTS_FREE[$pci]} - 1 ))
    else
        log_pairing_debug_state "$vmid" "$cpu_count"

        cpu_node_choice=$(find_best_cpu_only_node "$vmid" || true)
        if [[ -n "$cpu_node_choice" ]]; then
            IFS='|' read -r best_node max_free_cores <<< "$cpu_node_choice"
            GPU_FALLBACK_COUNT=$((GPU_FALLBACK_COUNT + 1))
            GPU_FALLBACK_VMIDS+=("$vmid")

            if (( slot_and_core_candidates > 0 && slot_core_hugepage_blocked == slot_and_core_candidates )); then
                warn "  Best-effort fallback for VM $vmid: GPU slot/core candidates were hugepage-blocked, assigning CPU/NUMA only on Node $best_node."
            else
                warn "  Best-effort fallback for VM $vmid: no valid GPU slot/core pair found, assigning CPU/NUMA only on Node $best_node."
            fi

            if [[ -n "$preferred_disk_node" ]]; then
                warn "    Disk prefers Node $preferred_disk_node via $preferred_disk_source (matched=$([ "$best_node" == "$preferred_disk_node" ] && echo yes || echo no), Node Free: $max_free_cores)"
            else
                warn "    Disk preference: none detected (Node Free: $max_free_cores)"
            fi

            assign_resources "$vmid" "$best_node" "" ""
            continue
        fi

        if (( slot_and_core_candidates > 0 && slot_core_hugepage_blocked == slot_and_core_candidates )); then
            error "VM $vmid has GPU slot/core candidate(s), but none have enough remaining 1G hugepages on their NUMA node, and no CPU-only fallback node is viable. Add per-node hugepages or reduce VM memory/host reservations."
        fi
        error "VM $vmid needs a GPU/CPU pair, but no valid slot/core combination was found and no CPU-only fallback node is viable."
    fi
done

if [[ $SKIP_GPU -eq 0 ]]; then
    total_gpu_assigned=$(( ${#VMS_TO_CONFIGURE[@]} - GPU_FALLBACK_COUNT ))
    log "  GPU planning result: ${total_gpu_assigned} VM(s) with GPU, ${GPU_FALLBACK_COUNT} VM(s) CPU-only (best effort)."
    if (( GPU_FALLBACK_COUNT > 0 )); then
        warn "  CPU-only fallback VM(s): ${GPU_FALLBACK_VMIDS[*]}"
    fi
fi

for node_id in "${NUMA_NODE_IDS[@]}"; do
    node_hp_total=${NODE_1G_HUGEPAGES_TOTAL[$node_id]:--1}
    node_hp_planned=${NODE_1G_HUGEPAGES_PLANNED[$node_id]:-0}
    node_hp_free=${NODE_1G_HUGEPAGES_FREE[$node_id]:--1}
    if (( node_hp_total >= 0 )); then
        log "  Node $node_id hugepages(1G): planned=${node_hp_planned}, total=${node_hp_total}, free=${node_hp_free}, safety_margin=${HUGEPAGE_NODE_SAFETY_PAGES}"
        if (( node_hp_free >= 0 && node_hp_planned > node_hp_free )); then
            warn "  Node $node_id: plan needs ${node_hp_planned}x1G hugepages but only ${node_hp_free} are free right now. Pages held by VMs being reconfigured free up when they restart; pages held by VMs outside this config do not -- starts may fail until then."
        fi
    elif (( node_hp_planned > 0 )); then
        warn "  Node $node_id: ${node_hp_planned}x1G hugepages planned, but this node exposes no 1G hugepage pool. VMs are configured with 'hugepages: 1024' and will not start until 1G pages exist (e.g. default_hugepagesz=1G hugepagesz=1G hugepages=N on the kernel cmdline)."
    fi
done

create_state_file
log "Planning Complete."

# The plan validates -- only now is it safe to start mutating the host.
log "--- PHASE 3.5: Applying Host Core Pinning ---"
apply_host_pinning


# =============================================================================
# --- PHASE 4: EXECUTION ---
# =============================================================================
log "--- PHASE 4: Executing Configuration ---"
if [[ $DRY_RUN -eq 1 ]]; then warn "*** DRY RUN MODE ***"; fi

# Apply one VM's plan. Each VM is independent and qm takes a per-VM config lock,
# so distinct VMIDs can be configured concurrently. Within a VM the qm calls stay
# ordered (later reads depend on earlier writes). Designed to run as a background
# job: logs are captured and replayed in VM order by the driver below.
execute_one_vm() {
    local vmid=$1
    log "--- Configuring VM $vmid ---"
    local plan=${VM_ASSIGNMENTS[$vmid]}

    # [FIX] Updated sed delimiters to match new plan format '|'
    local affinity node gpu_pci gpu_mdev cpu_count
    affinity=$(echo "$plan" | sed -n 's/.*cores=\([^|]*\).*/\1/p')
    node=$(echo "$plan" | sed -n 's/.*|node=\([^|]*\).*/\1/p')
    gpu_pci=$(echo "$plan" | sed -n 's/.*gpu_pci=\([^|]*\).*/\1/p')
    gpu_mdev=$(echo "$plan" | sed -n 's/.*mdev=\([^|]*\).*/\1/p')
    cpu_count=${VMS_TO_CONFIGURE[$vmid]}

    if [[ $DRY_RUN -eq 0 ]]; then
        local vm_cfg vm_mem numa0_spec line iface boot_disk disk_line disk_spec disk_opts disk_path scsihw
        qm set "$vmid" -cores "$cpu_count" -cpu "$CPU_CONFIG_STRING" -affinity "$affinity"

        # One config snapshot for all subsequent reads. (None of this run's
        # earlier writes change the keys read below, and the old per-read
        # `grep '^memory:'` killed the whole VM job under set -e when a config
        # had no explicit memory line.)
        vm_cfg=$(qm config "$vmid")
        vm_mem=$(echo "$vm_cfg" | awk '/^memory:/ {print $2; exit}')
        numa0_spec="cpus=0-$((cpu_count-1)),hostnodes=$node,memory=$vm_mem,policy=bind"
        if [[ -z "$vm_mem" ]]; then
            warn "  VM $vmid has no explicit memory setting; binding NUMA node without a memory clause."
            numa0_spec="cpus=0-$((cpu_count-1)),hostnodes=$node,policy=bind"
        fi
        qm set "$vmid" -numa 1 -numa0 "$numa0_spec" -hugepages 1024 -balloon 0

        if [[ $SKIP_GPU -eq 0 ]]; then
            if [[ -n "$gpu_pci" && -n "$gpu_mdev" ]]; then
                log "  Attaching GPU: $gpu_pci ($gpu_mdev)"
                qm set "$vmid" -hostpci0 "${gpu_pci},mdev=${gpu_mdev},pcie=1,x-vga=1"
            else
                warn "  No GPU assigned for VM $vmid (best-effort fallback)."
                if echo "$vm_cfg" | grep -q '^hostpci0:'; then
                    log "  Removing existing hostpci0 to match fallback plan."
                    qm set "$vmid" -delete hostpci0
                fi
            fi
        fi

        while read -r line; do
             iface=$(echo "$line" | cut -d: -f1)
             qm set "$vmid" -"$iface" "$(echo "$line" | cut -d' ' -f2 | sed -E 's/,?queues=[0-9]+//g'),queues=$cpu_count"
        done < <(echo "$vm_cfg" | grep -E '^net[0-9]+:.*virtio')

        boot_disk=$(echo "$vm_cfg" | grep '^boot:' | sed -e 's/.*order=//' -e 's/;.*//' || true)
        if [[ -n "$boot_disk" ]]; then
            if [[ "$boot_disk" =~ ^scsi ]]; then
                # iothread on a scsiX disk only takes effect with the
                # virtio-scsi-single controller; on any other scsihw qm either
                # rejects it or silently ignores it at VM start.
                scsihw=$(echo "$vm_cfg" | sed -n 's/^scsihw: *//p')
                if [[ "$scsihw" != "virtio-scsi-single" ]]; then
                    log "  Skipping IO Thread on $boot_disk: requires scsihw=virtio-scsi-single (current: ${scsihw:-default})."
                    boot_disk=""
                fi
            elif [[ ! "$boot_disk" =~ ^virtio ]]; then
                log "  Skipping IO Thread for bus: $boot_disk (not supported)"
                boot_disk=""
            fi
        fi
        if [[ -n "$boot_disk" ]]; then
            disk_line=$(echo "$vm_cfg" | grep "^${boot_disk}:" || true)
            if [[ -n "$disk_line" && "$disk_line" != *"iothread=1"* ]]; then
                disk_spec=$(echo "$disk_line" | awk '{print $2}')
                disk_path=${disk_spec%%,*}
                log "  Enabling IO Thread on $boot_disk"
                if [[ "$disk_spec" == *,* ]]; then
                    disk_opts=${disk_spec#*,}
                    qm set "$vmid" -"$boot_disk" "${disk_path},${disk_opts},iothread=1"
                else
                    # No existing options: the old `cut -f2-` duplicated the
                    # volume here ("path,path,iothread=1") and qm rejected it.
                    qm set "$vmid" -"$boot_disk" "${disk_path},iothread=1"
                fi
            fi
        fi

        if [[ -n "$HOOK_SCRIPT_PATH" ]]; then qm set "$vmid" --hookscript "$HOOK_SCRIPT_PATH"; fi

        # qm set on a RUNNING VM stages most of these options as "pending"
        # changes that only take effect at the next power cycle. Detect that
        # and say so, instead of implying the new pinning is already live.
        local vm_status pending_count
        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}' || true)
        if [[ "$vm_status" == "running" ]]; then
            pending_count=$(qm pending "$vmid" 2>/dev/null | grep -cE '^[[:space:]]*(pending|delete)' || true)
            if [[ "$pending_count" =~ ^[0-9]+$ ]] && (( pending_count > 0 )); then
                touch "${_p4_tmp}/${vmid}.restart"
                warn "  VM $vmid is running: $pending_count change(s) are PENDING until it is power-cycled."
            fi
        fi
    else
        log "  [DRY RUN] Set Affinity: $affinity (Node $node)"
        if [[ -n "$gpu_pci" ]]; then
            log "  [DRY RUN] Set GPU: $gpu_pci ($gpu_mdev)"
        elif [[ $SKIP_GPU -eq 0 ]]; then
            warn "  [DRY RUN] No GPU assigned (best-effort fallback)."
        fi
    fi
}

# Fan out VM configuration across the job pool. The function call is a standalone
# simple command (NOT part of a && / || list) so set -e stays active inside it: a
# failing qm step aborts that VM's remaining steps -- exactly as the sequential
# script did -- which skips the trailing "touch .ok". Absence of the .ok marker
# therefore means that VM failed. One bad VM no longer stops the others, but the
# run still aborts non-zero at the end if any VM failed.
_p4_tmp=$(mktemp -d)
parallel_begin "VM configuration" "${#VMS_TO_CONFIGURE[@]}"
for vmid in "${!VMS_TO_CONFIGURE[@]}"; do
    parallel_throttle
    { execute_one_vm "$vmid" > "$_p4_tmp/${vmid}.log" 2>&1; touch "$_p4_tmp/${vmid}.ok"; } &
    parallel_track "VM $vmid" $!
done
parallel_drain

_p4_failed=()
_p4_restart=()
for vmid in $(printf '%s\n' "${!VMS_TO_CONFIGURE[@]}" | sort -n); do
    if [[ -f "$_p4_tmp/${vmid}.log" ]]; then replay_captured "$_p4_tmp/${vmid}.log"; fi
    if [[ -f "$_p4_tmp/${vmid}.restart" ]]; then _p4_restart+=("$vmid"); fi
    [[ -f "$_p4_tmp/${vmid}.ok" ]] || _p4_failed+=("$vmid")
done
rm -rf "$_p4_tmp"

if (( ${#_p4_failed[@]} > 0 )); then
    error "Configuration failed for VM(s): ${_p4_failed[*]}"
fi

# Every VM applied cleanly -- rewrite the state file marked as applied, so the
# file can be trusted as a record of what is actually configured on the host.
if [[ $DRY_RUN -eq 0 ]]; then
    STATE_APPLIED="true"
    create_state_file
fi

if (( ${#_p4_restart[@]} > 0 )); then
    warn "PENDING CHANGES: VM(s) ${_p4_restart[*]} are running and must be power-cycled (qm shutdown <id> && qm start <id>) before the new affinity/NUMA/GPU layout takes effect."
fi

log "Script finished."
