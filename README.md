# Affinity Manager

A single Bash script for Proxmox that pins VM CPUs to dedicated cores and hands out
NVIDIA vGPU slots automatically. It reads a JSON config, works out a NUMA-aware,
load-balanced layout — placing each VM on the NUMA node where its disk lives when it
can — reserves cores for the host, and applies everything with `qm`. It can also run
CPU-only.

Everything is validated **before** anything is mutated: VM existence, core counts,
host-core topology and plan feasibility are checked first, and host pinning (systemd
slices, GRUB, IRQ confinement) is only applied once the whole plan is known good.
Concurrent runs are serialized with a lock.

## Requirements

`qm`, `jq`, `lscpu`, `lspci`, and `bc` on the host — a standard Proxmox node with the
NVIDIA vGPU drivers already has these. (`nvidia-smi`, `lsblk`, `flock`, and the LVM
tools are used automatically when present.)

## Usage

```bash
# Preview the plan without changing anything
./manager.sh -f config.json -n

# Apply it (as root)
sudo ./manager.sh -f config.json
```

If any configured VM is running, its changes land as Proxmox *pending* changes; the
script ends with an explicit list of VMs that must be power-cycled before the new
layout takes effect.

Every run (including dry runs) ends with **post-run checks** — the things one run
cannot fully fix by itself: whether a **reboot** is required because the booted
kernel does not match the GRUB isolation params (or GRUB still lacks the planned
ones), whether `affinity-manager-irq.service` is enabled so IRQ confinement
survives reboots, and whether every managed VM has a pinning **hookscript**
attached. These are warnings only; they never change the exit code.

### Options

| Flag | Description |
|------|-------------|
| `-f <config.json>` | Path to the config file. Required. |
| `-n` | Dry run — print the plan, change nothing. |
| `-a [N]` | Auto-select host cores, consolidated on the least GPU-loaded NUMA node (N per node, default 1). |
| `-b [N]` | Auto-select host cores, balanced across physical sockets (N physical + N SMT per socket). |
| `-g` | Skip GPU discovery and assignment — CPU-only. |
| `-i` | Only re-apply device IRQ confinement, then exit (see persistence below). |
| `-s <volume-id>` | Attach a hook script to each VM (a snippets volume ID, e.g. `local:snippets/vcpu-pin-hook.sh`). |
| `-r` | Print the commands to undo host core pinning. |
| `--no-reserve` | Run without host core reservation (overrides `reserve_host_cores`) and remove a previously applied reservation. See below. |
| `-h` | Show usage and exit. |

`-a` and `-b` write the cores they pick back into the config (a timestamped backup is made first).

### Running without host core reservation

On small hosts it can make sense to give **every** thread to the VMs — e.g. 8 threads
total with two 4-thread VMs — and let the host services share the cores instead of
reserving any. Set `"reserve_host_cores": false` in the config (or pass `--no-reserve`
to override a config that says `true`): the planner then treats all CPUs as available
and the VMs still get NUMA-aware, non-overlapping affinity sets.

A previous *reserving* run's leftovers would actively fight such a plan (a stale
`qemu.slice` `AllowedCPUs=` keeps VMs off the ex-host cores), so a run with
reservation disabled also **removes** them: the slice cpusets are reset, the
`99-host-cores.conf` / `99-vm-cores.conf` drop-ins deleted, the
`isolcpus`/`nohz_full`/`rcu_nocbs` GRUB params stripped (only when they carry this
script's `isolcpus=managed_irq,domain,…` signature — a foreign `isolcpus` is left
alone with a warning), device IRQs whose affinity was confined to the former host
cores are widened back to all CPUs (any other IRQ placement is presumed deliberate
and untouched), and an enabled `affinity-manager-irq.service` is disabled (it
requires a reservation).
The removal is evidence-based and idempotent: a host that never had a reservation
applied is a no-op, and dry runs (`-n`) only print the commands. As with applying
the params, removing them from GRUB needs `update-grub` and a **reboot** to take
effect — the post-run checks flag this until the booted kernel is clean.

## Configuration

```json
{
  "global_settings": {
    "cpu_config_string": "host,flags=+md-clear;-pcid;-spec-ctrl;-ssbd;+pdpe1gb;+hv-tlbflush;+aes",
    "reserve_host_cores": true,
    "host_cores": [0, 44, 22, 66],
    "state_file": "/var/tmp/proxmox_cpu_affinity.state"
  },
  "gpu_settings": {
    "required_vram_mb": 2048,
    "auto_detect_profile": false,
    "gpu_profile_map": {
      "0000:04:00.0": "nvidia-47"
    }
  },
  "tuning_settings": {
    "disable_numa_balancing": true,
    "disable_ksm": true,
    "cpu_governor": "performance"
  },
  "vms": {
    "101": 4,
    "102": 4
  }
}
```

**global_settings**
- `cpu_config_string` — CPU type and flags passed to the VMs.
- `reserve_host_cores` — keep `host_cores` for the host and pin VMs off them.
  Set to `false` to hand every core to the VMs *and* remove a previously applied
  reservation (see "Running without host core reservation" above).
- `host_cores` — CPU IDs reserved for the host (or leave it and use `-a`/`-b`).
  Entries are validated against the actual topology.
- `state_file` — where the plan record is written (default `manager_state.json`).
  Dry runs write to `<state_file>.dryrun` so a preview never overwrites the record
  of the last real apply. The file carries `metadata.applied`: written `false` when
  planning completes, rewritten `true` only after every VM applied cleanly — so
  `applied: false` in a non-dryrun state file means the apply phase did not finish.
- `parallel_jobs` — max concurrent jobs for GPU probing, disk detection, and VM
  config. Optional; defaults to the host CPU count (`nproc`). Set to `1` to force
  fully sequential execution.

**gpu_settings**
- `required_vram_mb` — VRAM per vGPU slot.
- `auto_detect_profile` — pick the vGPU profile by VRAM automatically.
- `gpu_profile_map` — pin a specific vGPU profile to a GPU by PCI address.

**tuning_settings** (all optional, all default off — they change host-global behavior)
- `disable_numa_balancing` — automatic NUMA balancing migrates tasks/pages to chase
  locality the plan has already fixed; disabling it removes that overhead. Applied
  live and persisted via `/etc/sysctl.d/`.
- `disable_ksm` — KSM cannot merge hugetlbfs-backed guests, so with 1G hugepages
  ksmd/ksmtuned is pure CPU overhead on the host cores. Stops both and unmerges.
- `cpu_governor` — cpufreq governor to set on the VM cores (e.g. `"performance"`).

**vms** — map of VM ID to the number of cores it gets. Each VM targets one vGPU slot
(falling back to CPU-only if none fits, or always with `-g`).

Disk locality is detected automatically. To hint it, add an optional `disk_settings`
block mapping a VM or storage to a node, e.g.
`{ "disk_settings": { "vm_node_map": { "101": "node:0" } } }`.

## How VMs are kept on their cores

- Each VM gets `qm set -affinity` with its planned cores: physical cores first, and
  when SMT threads are needed, the **siblings of that VM's own physical cores** — so
  both threads of a core belong to one VM and no other VM shares its pipeline.
  Physical-vs-SMT classification comes from the lscpu core map, so interleaved
  sibling numbering (AMD EPYC style) is handled correctly.
- The host slices (`system.slice`, `user.slice`, `init.scope`) are restricted to the
  reserved host cores, and `qemu.slice` (where Proxmox actually runs QEMU guests)
  gets an `AllowedCPUs=` drop-in for the VM cores — this also keeps VMs that are
  *not* in the config off the host cores.
- GRUB gets `isolcpus=managed_irq,domain`, `nohz_full` and `rcu_nocbs` for the VM
  cores (run `update-grub` and reboot to activate).
- Movable device IRQs that overlap VM cores are steered onto the host cores.

### Per-vCPU 1:1 pinning + helper spread (extras/vcpu-pin-hook.sh)

`qm`'s affinity is one shared mask for every thread of the VM — and on a host with
`isolcpus=domain` the scheduler does no load balancing *inside* that mask, so the
QEMU main loop, iothreads and vhost-net workers all stack on whichever CPU they were
forked on (typically vCPU 0's core, where they then compete with the guest). The
bundled hookscript fixes both at every VM start:

- libvirt-style vcpupin: vCPU *k* is pinned to the *k*-th CPU of the affinity list;
- every other thread of the QEMU process (main loop, iothreads, vhost workers, KVM
  housekeeping) is pinned round-robin over the affinity cores in **reverse** order,
  so helpers land away from vCPU 0's core first instead of stacking on it.

Threads the VM spawns *after* the hook ran (QEMU thread-pool / io_uring workers)
inherit their parent's single-CPU pin rather than the full mask — still inside the
VM's own cores, and better than the pre-hook behavior where they all landed on one
core. Re-running the hook by hand (`cpu-pin.sh <vmid> post-start`) redistributes
them at any time.

Besides stdout (captured in the Proxmox VM-start task log) the hook appends to
`/var/log/cpu-pin.log`; set `VCPU_PIN_LOG=` (empty) to disable that — and give it
a logrotate entry if your VMs restart frequently.

One flag installs (or refreshes) the snippet and attaches it to every managed VM:

```bash
sudo ./manager.sh -f config.json --install-hook                              # default: local:snippets/vcpu-pin-hook.sh
sudo ./manager.sh -f config.json --install-hook local:snippets/cpu-pin.sh    # custom volume ID
```

The target path is resolved from the volume ID via `pvesm path`; an existing file
with different content is backed up to a timestamped `<name>.bak.<ts>` before being
replaced (atomically), and the post-run checks warn whenever an attached hook's
content drifts from the bundled `extras/` copy — or points at a file that no longer
exists. Manual install works too:

```bash
cp extras/vcpu-pin-hook.sh /var/lib/vz/snippets/
chmod +x /var/lib/vz/snippets/vcpu-pin-hook.sh
sudo ./manager.sh -f config.json -s local:snippets/vcpu-pin-hook.sh
```

### IRQ confinement persistence (extras/affinity-manager-irq.service)

`/proc/irq` affinity resets on every reboot (and on NIC driver re-init). The systemd
drop-ins and GRUB params persist, the IRQ placement does not — re-apply it with
`manager.sh -f config.json -i`, or install the oneshot unit that does it at boot:

```bash
sudo ./manager.sh -f config.json --install-irq-service
```

This generates `/etc/systemd/system/affinity-manager-irq.service` with `ExecStart`
pointing at the **absolute paths of this script and this config** (no hand-editing),
reloads systemd, and enables it. Idempotent; re-run it after moving the repo or the
config. The bundled `extras/affinity-manager-irq.service` remains as a template for
manual installs (adapt the two `ExecStart` paths yourself).

## Examples

```bash
# Auto-pick least-used node, then reserve host cores (1 physical + 1 SMT)
sudo ./manager.sh -f config.json -a 1

# Balance host cores across sockets (2 physical + 2 SMT each)
sudo ./manager.sh -f config.json -b 2

# CPU-only, no GPU assignment
sudo ./manager.sh -f config.json -g

# Hand ALL cores to the VMs and remove any existing host core reservation
sudo ./manager.sh -f config.json --no-reserve

# Re-apply IRQ confinement after a NIC reset
sudo ./manager.sh -f config.json -i

# First-time setup: pin everything AND install the hook + boot-time IRQ unit
sudo ./manager.sh -f config.json --install-hook --install-irq-service
```

## Tests

`tests/run.sh` runs the full pipeline end-to-end with `qm`, `lscpu`, `lspci`,
`systemctl`, `nvidia-smi` and `taskset` stubbed via `PATH`, and every `/etc` and
`/sys` touchpoint redirected at fixture trees — including the real (non-dry-run)
apply path, GPU slot pairing, SMT sibling allocation, and failure-ordering
guarantees. Runs in any container:

```bash
sudo bash tests/run.sh
```

CI (GitHub Actions) runs `shellcheck` and the harness on every push.
