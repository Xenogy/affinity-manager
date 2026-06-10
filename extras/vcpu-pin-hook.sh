#!/usr/bin/env bash
# Proxmox VM hookscript: pin each vCPU thread 1:1 to the cores of the VM's
# affinity mask, and spread the VM's helper threads across the same cores.
#
# `qm set -affinity` constrains ALL of the VM's threads (vCPUs, the QEMU main
# loop, iothreads, vhost workers) to one shared mask. On a host with
# isolcpus=domain that is not enough: the scheduler does no load balancing
# inside the mask, so (a) vCPUs migrate or stack arbitrarily and (b) every
# helper thread stays on whichever CPU it was forked on -- typically the same
# core as vCPU 0, where it then competes with the guest. At every VM start
# this hook therefore applies:
#   - libvirt-style vcpupin: vCPU k -> the k-th CPU of the affinity list
#     (the order manager.sh planned: physical cores first, then their SMT
#     siblings);
#   - helper distribution: every other thread of the QEMU process (main loop,
#     iothreads, vhost-net workers, KVM housekeeping) is pinned round-robin
#     over the affinity cores in REVERSE order, so helpers land on the SMT
#     half first and on vCPU 0's core last.
#
# Install (requires a storage with the 'snippets' content type):
#   cp extras/vcpu-pin-hook.sh /var/lib/vz/snippets/
#   chmod +x /var/lib/vz/snippets/vcpu-pin-hook.sh
#   qm set <vmid> --hookscript local:snippets/vcpu-pin-hook.sh
# or attach it to every managed VM in one go:
#   ./manager.sh -f config.json -s local:snippets/vcpu-pin-hook.sh
#
# Never fails the VM start: every problem is a warning, exit code is 0.
set -uo pipefail

VMID="${1:-}"
PHASE="${2:-}"

# Test hooks (defaults are the real locations).
QEMU_PID_DIR="${QEMU_PID_DIR:-/var/run/qemu-server}"
PROC_BASE="${PROC_BASE:-/proc}"
# Best-effort append-only log file, in addition to stdout (which Proxmox
# captures in the VM start task log). Set empty to disable.
VCPU_PIN_LOG="${VCPU_PIN_LOG-/var/log/cpu-pin.log}"

_logfile() {
    [[ -n "$VCPU_PIN_LOG" ]] || return 0
    echo "$(date '+%F %T') [vm $VMID] $*" >> "$VCPU_PIN_LOG" 2>/dev/null || true
}
log()  { echo "[vcpu-pin-hook] $*"; _logfile "$*"; }
warn() { echo "[vcpu-pin-hook] WARNING: $*" >&2; _logfile "WARNING: $*"; }

[[ "$PHASE" == "post-start" ]] || exit 0
[[ -n "$VMID" ]] || exit 0

affinity=$(qm config "$VMID" --current 2>/dev/null | sed -n 's/^affinity: *//p')
if [[ -z "$affinity" ]]; then
    log "VM $VMID has no affinity set; nothing to pin."
    exit 0
fi

# Expand "1,2,9-11" into an ordered array; list order defines the vCPU mapping.
cores=()
IFS=',' read -ra _tokens <<< "$affinity"
for tok in "${_tokens[@]}"; do
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for (( c=BASH_REMATCH[1]; c<=BASH_REMATCH[2]; c++ )); do cores+=("$c"); done
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
        cores+=("$tok")
    fi
done
if (( ${#cores[@]} == 0 )); then
    warn "could not parse affinity '$affinity' for VM $VMID."
    exit 0
fi

pid_file="$QEMU_PID_DIR/$VMID.pid"
pid=""
for _attempt in 1 2 3 4 5; do
    if [[ -r "$pid_file" ]]; then pid=$(<"$pid_file"); fi
    if [[ -n "$pid" && -d "$PROC_BASE/$pid/task" ]]; then break; fi
    sleep 1
done
if [[ -z "$pid" || ! -d "$PROC_BASE/$pid/task" ]]; then
    warn "no QEMU process found for VM $VMID (pid file: $pid_file); skipping."
    exit 0
fi

# vCPU threads are named "CPU <n>/KVM"; give them a moment to spawn.
pinned=0
for _attempt in 1 2 3 4 5; do
    pinned=0
    for task_dir in "$PROC_BASE/$pid/task"/*; do
        [[ -r "$task_dir/comm" ]] || continue
        comm=$(<"$task_dir/comm")
        if [[ "$comm" =~ ^CPU\ ([0-9]+)/KVM$ ]]; then
            idx=${BASH_REMATCH[1]}
            tid=${task_dir##*/}
            if (( idx >= ${#cores[@]} )); then
                warn "vCPU $idx of VM $VMID has no matching core in affinity '$affinity'; leaving it on the shared mask."
                continue
            fi
            if taskset -pc "${cores[idx]}" "$tid" > /dev/null 2>&1; then
                log "VM $VMID vCPU $idx (tid $tid) -> CPU ${cores[idx]}"
                pinned=$((pinned + 1))
            else
                warn "failed to pin vCPU $idx (tid $tid) of VM $VMID to CPU ${cores[idx]}."
            fi
        fi
    done
    if (( pinned > 0 )); then break; fi
    sleep 1
done

if (( pinned == 0 )); then
    warn "no vCPU threads found/pinned for VM $VMID."
else
    log "pinned $pinned vCPU thread(s) of VM $VMID 1:1 onto: $affinity"
fi

# --- Helper threads: QEMU main loop, iothreads, vhost workers, etc. ---
# (On kernel >= 6.4 vhost workers are user-worker tasks and appear under the
# QEMU process's task dir, so one scan covers them too.) Reverse round-robin
# so the first helpers land farthest from vCPU 0's core.
rev_cores=()
for (( i=${#cores[@]}-1; i>=0; i-- )); do rev_cores+=("${cores[i]}"); done
helpers=0
helpers_failed=0
for task_dir in "$PROC_BASE/$pid/task"/*; do
    [[ -r "$task_dir/comm" ]] || continue
    comm=$(<"$task_dir/comm")
    [[ "$comm" =~ ^CPU\ [0-9]+/KVM$ ]] && continue
    tid=${task_dir##*/}
    target=${rev_cores[$(( helpers % ${#rev_cores[@]} ))]}
    if taskset -pc "$target" "$tid" > /dev/null 2>&1; then
        log "VM $VMID helper '$comm' (tid $tid) -> CPU $target"
        helpers=$((helpers + 1))
    else
        # Transient threads (io_uring / thread-pool workers) can exit between
        # the readdir and the taskset, or reject affinity changes; not fatal.
        helpers_failed=$((helpers_failed + 1))
    fi
done
if (( helpers_failed > 0 )); then
    warn "could not pin $helpers_failed helper thread(s) of VM $VMID (transient or affinity-restricted)."
fi
log "distributed $helpers helper thread(s) of VM $VMID over: $(IFS=,; echo "${rev_cores[*]}")"
exit 0
