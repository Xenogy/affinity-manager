#!/usr/bin/env bash
# Proxmox VM hookscript: pin each vCPU thread 1:1 to the cores of the VM's
# affinity mask.
#
# `qm set -affinity` constrains ALL of the VM's threads (vCPUs, the QEMU main
# loop, iothreads) to one shared mask: vCPUs migrate within it and compete
# with each other and with the emulator for the same cores. This hook adds
# libvirt-style vcpupin on top at every VM start: vCPU k -> the k-th CPU of
# the affinity list (the order manager.sh planned: physical cores first, then
# their SMT siblings). Non-vCPU threads keep the full shared mask.
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

log()  { echo "[vcpu-pin-hook] $*"; }
warn() { echo "[vcpu-pin-hook] WARNING: $*" >&2; }

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
exit 0
