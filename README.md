# Affinity Manager

A single Bash script for Proxmox that pins VM CPUs to dedicated cores and hands out
NVIDIA vGPU slots automatically. It reads a JSON config, works out a NUMA-aware,
load-balanced layout — placing each VM on the NUMA node where its disk lives when it
can — reserves cores for the host, and applies everything with `qm`. It can also run
CPU-only.

## Requirements

`qm`, `jq`, `lscpu`, `lspci`, and `bc` on the host — a standard Proxmox node with the
NVIDIA vGPU drivers already has these. (`nvidia-smi`, `lsblk`, and the LVM tools are
used automatically when present.)

## Usage

```bash
# Preview the plan without changing anything
./manager.sh -f config.json -n

# Apply it (as root)
sudo ./manager.sh -f config.json
```

### Options

| Flag | Description |
|------|-------------|
| `-f <config.json>` | Path to the config file. Required. |
| `-n` | Dry run — print the plan, change nothing. |
| `-a [N]` | Auto-select host cores, consolidated on the least GPU-loaded NUMA node (N per node, default 1). |
| `-b [N]` | Auto-select host cores, balanced across physical sockets (N physical + N SMT per socket). |
| `-g` | Skip GPU discovery and assignment — CPU-only. |
| `-s <script>` | Attach a hook script to each VM. |
| `-r` | Print the commands to undo host core pinning. |
| `-h` | Show usage and exit. |

`-a` and `-b` write the cores they pick back into the config (a timestamped backup is made first).

## Configuration

```json
{
  "global_settings": {
    "cpu_config_string": "host,flags=+aes",
    "reserve_host_cores": true,
    "host_cores": [0, 44, 22, 66]
  },
  "gpu_settings": {
    "required_vram_mb": 2048,
    "auto_detect_profile": false,
    "gpu_profile_map": {
      "0000:04:00.0": "nvidia-47"
    }
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
- `host_cores` — CPU IDs reserved for the host (or leave it and use `-a`/`-b`).

**gpu_settings**
- `required_vram_mb` — VRAM per vGPU slot.
- `auto_detect_profile` — pick the vGPU profile by VRAM automatically.
- `gpu_profile_map` — pin a specific vGPU profile to a GPU by PCI address.

**vms** — map of VM ID to the number of cores it gets. Each VM targets one vGPU slot
(falling back to CPU-only if none fits, or always with `-g`).

Disk locality is detected automatically. To hint it, add an optional `disk_settings`
block mapping a VM or storage to a node, e.g.
`{ "disk_settings": { "vm_node_map": { "101": "node:0" } } }`.

## Examples

```bash
# Auto-pick one host core per NUMA node, then apply
sudo ./manager.sh -f config.json -a 1

# Balance host cores across sockets (2 physical + 2 SMT each)
sudo ./manager.sh -f config.json -b 2

# CPU-only, no GPU assignment
sudo ./manager.sh -f config.json -g
```
