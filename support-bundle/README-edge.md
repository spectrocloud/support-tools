# Edge Support Bundle Collection Script

This Bash script (`support-bundle-edge.sh`) is designed to collect various logs from an edge host and a Kubernetes cluster. The collected logs are then archived for troubleshooting and support purposes.

## Quick Start

To collect edge support bundle, you can use either of these methods:

Using the official SpectroCloud software URL:
```bash
curl -sSL https://software.spectrocloud.com/scripts/support-bundle-edge.sh
sudo bash support-bundle-edge.sh
```

Or using the GitHub repository URL:
```bash
curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-edge.sh
sudo bash support-bundle-edge.sh
```

## Prerequisites

* Run the script as a user with `sudo` privileges
* Run the script on all edge hosts
* Required dependencies:
  - `journalctl`: For accessing system journal logs
  - `systemctl`: For checking systemd services status
  - `kubectl`: For interacting with Kubernetes clusters

## Usage

Basic usage:
```bash
./support-bundle-edge.sh
```

Advanced usage with additional collection options:
```bash
./support-bundle-edge.sh -n hello-universe,hello-world -r certificates.cert-manager.io -R clusterissuers.cert-manager.io -j cloud-init,systemd-resolved
```

## Available Flags

All flags are optional:

| Flag | Description | Example |
|------|-------------|---------|
| `-d` | Output directory for temporary storage and .tar.gz archive | `-d /var/tmp` |
| `-s` | Start day of journald log collection | `-s 7` (7 days ago) |
| `-e` | End day of journald log collection | `-e 5` (5 days ago) |
| `-S` | Start date of journald log collection | `-S 2024-01-01` |
| `-E` | End date of journald log collection | `-E 2024-01-01` |
| `-l` | Number of log lines to collect | `-l 500000` |
| `-n` | Additional namespaces to collect | `-n hello-universe,hello-world` |
| `-r` | Additional namespace scoped resources | `-r certificates.cert-manager.io` |
| `-R` | Additional cluster scoped resources | `-R clusterissuers.cert-manager.io` |
| `-j` | Additional journald logs to collect | `-j cloud-init,systemd-resolved` |

## Environment Variables

* `KUBECONFIG`: Path to the Kubernetes configuration file
  * Default: `/run/kubeconfig` if not specified

## Important Notes

* Secrets are not collected as part of the support bundle
* Only helm release secrets for the spectrocloud namespaces are collected
* The script automatically detects the Kubernetes distribution (kubeadm, k3s, or rke2)
* Collected logs are stored in `/opt/spectrocloud/logs/` by default

## Output

The script creates a compressed tarball (`*.tar.gz`) containing all collected logs. The filename includes:
* Hostname
* Timestamp of collection

Example: `hostname-2024-03-21_14_30_45.tar.gz`

The tar archive is saved in `$TMPDIR` by default. You can specify a different output directory using the `-d` flag when running the script.

## Collected Information

The script collects various types of information:

### System Information
* System logs (journald)
* Network configuration
* System services status
* Host information
* Time synchronization (chronyd/NTP configuration and status)

### Kubernetes Information
* Cluster information
* Resource states
* Pod logs
* Custom resources
* Metrics
* Helm releases

### Container Information
* Container runtime logs
* Container status
* Container metrics

### Edge-specific Information
* Stylus agent logs
* Palette agent logs
* Installation-time logs
* Edge cluster configuration
* System upgrade information

## Collection Details

This document provides transparency about the output collected when running the support bundle script. The collection is designed to gather necessary troubleshooting information while respecting privacy and security concerns.

Where possible, output from the collection is sanitized. However, we recommend you check the log collection and remove or edit any sensitive data before sharing.

### Node-level Collection

Output that is collected only from the node where the support bundle script is run:

#### Operating System
* General OS configuration:
  * Hostname and system information
  * Resource utilization
  * Process list
  * Service list
  * System packages
  * System limits and tunables
* Networking information:
  * iptables rules
  * netstat output
  * Network interfaces
  * CNI configuration
* System logs:
  * Journalctl output for related services (see `JOURNALD_LOGS` variable in script)
  * OS logs from /var/log
  * System service logs
* Time synchronization:
  * chronyd tracking status and NTP sources
  * chronyd configuration files (/etc/chrony.conf, /etc/chrony.d/*)
  * chronyd service status and drift file
  * timedatectl status output
  * systemd-timesyncd logs (if applicable)

#### Kubernetes Distribution
* Distribution-specific logs:
  * k3s agent/server logs
  * rke2 agent/server logs
  * kubeadm logs
* Distribution configuration:
  * k3s configuration files
  * rke2 configuration files
  * Static pod manifests
* Container runtime:
  * containerd logs and configuration
  * Container runtime status and metrics

### Cluster-level Collection

Output that is collected from the cluster. Note that pod logs from other nodes and additional kubectl output can only be collected when running on a control plane/server node.

#### Kubernetes Components
* Control plane components:
  * kube-apiserver configuration and logs
  * kube-scheduler logs
  * kube-controller-manager logs
  * etcd logs and configuration
* Worker components:
  * kubelet configuration and logs
  * Container runtime logs
* System directories:
  * Kubernetes manifests
  * SSL certificates
  * etcd data (if applicable)

#### Kubernetes Resources
* Cluster resources:
  * Nodes information
  * Pod status and logs
  * Services configuration
  * RBAC roles and bindings
  * Persistent volumes
  * Events
  * Ingress configurations
  * Deployments and other workloads
* Custom resources:
  * Cluster API objects
  * Palette-specific resources
  * Other custom resources in system namespaces

### Edge-specific Collection

* Stylus agent logs and configuration
* Palette agent logs and status
* Installation-time logs (collected only if present)
* Edge cluster configuration
* System upgrade information
* Edge-specific custom resources
* Edge networking configuration

### Storage / LVM / NVMe Collection

Palette edge hosts run on LVM (`spectro-data-vg` / `spectro-data-lv` with the persistent partition at `/opt`), and AI appliances additionally park model weights under `/opt/data/spectrocloud/models/` (hundreds of GB per model). Storage health is load-bearing for triage. The `storage-info` step collects:

* `lsblk -f` (filesystem labels/UUIDs/mountpoints) and detailed `lsblk` with model/serial/transport/rotational
* `df -h` and `df -i` (filesystem + inode usage)
* `/proc/mounts` and `/etc/fstab`
* `fdisk -l` (partition tables) — when available
* LVM: `pvdisplay`, `vgdisplay`, `lvdisplay` and their compact counterparts `pvs` / `vgs` / `lvs` — when LVM tools are installed
* NVMe: `nvme list`, `nvme id-ctrl`, `nvme smart-log` per drive — when `nvme-cli` is installed
* SMART: `smartctl -a` per block device — when `smartmontools` is installed

Silently skips per-tool blocks when the binary isn't present, so this is safe on any host.

### AI / GPU Collection (launchpad-ai appliances)

For AI-inference appliances (`launchpad-ai`) and other GPU-bearing edge nodes, the script collects vendor-specific GPU state alongside the standard Kubernetes and system collection. Emits an empty `gpu/` directory on non-GPU hosts — safe to run everywhere.

#### Namespaces included by default
The `launchpad-ai`, `amd-gpu-operator`, and `gpu-operator` namespaces are collected without needing `-n`. This covers the gateway, local-models-scanner, semantic router, UI, engine (vLLM) pods and their previous-instance logs, plus AMD/NVIDIA operator components.

#### Custom resources
All `launchpad.spectrocloud.com/v1alpha1` CRs are collected via the generic CRD walk — `models`, `launchpadconfigs`, `modelgroupquotas`, `modelgroupapikeys`, `quotasettings`. Also the on-node `launchpad-local-models-edge-<node-id>` ConfigMap (source-of-truth for the reconcile loop).

#### AMD (amdgpu / ROCm) — collected when `/sys/module/amdgpu` exists
* Driver: `/sys/module/amdgpu/version`, full `modinfo amdgpu`, all `/sys/module/amdgpu/parameters/*` values (lockup_timeout, reset_method, gpu_recovery, etc.)
* Per-card VBIOS via `/sys/bus/pci/devices/*/vbios_version`
* Per-card firmware components via `/sys/bus/pci/devices/*/fw_version/*` (sdma_fw_version, sos_fw_version, smc_fw_version, ta_xgmi_fw_version, mec_fw_version, rlc_fw_version, etc.) — heterogeneous firmware across cards is a documented failure mode
* Per-card RAS state and ECC error counters via `/sys/bus/pci/devices/*/ras/*`
* Per-card temperature / power / voltage / fan via sysfs `hwmon`
* `rocm-smi -a` and `rocm-smi --showhw --showdriverversion --showvbios --showtemp --showuse --showpower --showfw --showbios` — sourced from the host if `rocm-smi` is installed, else via `kubectl exec` into any pod in `amd-gpu-operator` or `launchpad-ai` that has the tool
* AMD GPU device coredumps from `/var/log/amdgpu-devcoredump/` (populated by the udev rule shipped in the AMD OS profile — the ONLY forensic evidence available for post-mortem RCA of SDMA/GFX/KIQ ring hangs, since kernel devcoredumps are otherwise freed on read/timeout/reboot)
* Live sysfs devcoredump listing (`/sys/class/devcoredump/`)

#### NVIDIA (nvidia driver) — collected when `/proc/driver/nvidia` exists or `nvidia-smi` is present
* Driver version from `/proc/driver/nvidia/version`
* `nvidia-smi -q` (full attribute dump), `nvidia-smi topo -m` (NVLink/PCIe topology), plus a compact CSV summary of per-GPU state (pstate, temp, util, memory, ECC corrected + uncorrected counts) — sourced from the host if `nvidia-smi` is installed, else via `kubectl exec` into any running pod in `gpu-operator` or `launchpad-ai`
* `nvidia-bug-report.sh` output if the tool is installed (comprehensive vendor-side dump)
* NVIDIA GPU device coredumps from `/var/log/nvidia-devcoredump/` (populated by the udev rule shipped in the NVIDIA OS profile)

#### launchpad-ai on-disk state
* Directory shape (not contents) of `/opt/data/spectrocloud/models/` — weights are hundreds of GB and are never copied into the bundle
* `metadata.yaml` files for every locally-installed model (small, ~20 KB each) — these declare the exact recipe used to launch each engine (image, TP width, quantization, extra_args, env vars). Essential context for engine-crash triage.

#### Kernel evidence (previous boot)
* `dmesg-previous-boot` and `journalctl-previous-boot` — full kernel log from the boot BEFORE this one. Present only when journald has persistent storage (`/var/log/journal/` populated). Critical for post-crash forensics: if a GPU wedge caused the host to lose networking and reboot, the surviving evidence is here.

### MongoDB Collection (Enterprise Clusters Only)

For Enterprise and PCG clusters, the script collects MongoDB replica set information:

* `rs-status.json`: Replica set status including member health, sync state, and election info
* `rs-conf.json`: Replica set configuration including member settings and priorities
* `replication-info.txt`: Oplog information and replication window
* `disk-usage.txt`: Actual `df -h /var/lib/mongodb` per mongo pod — the real on-disk size, which can differ from the requested PVC/PV size on thin-provisioned or fixed-disk-offering backends (e.g. CloudStack fixed offerings)
* `db-collection-sizes.txt`: Per-database and per-collection storage/data sizes (MB) and document counts — shows which collections are consuming disk
