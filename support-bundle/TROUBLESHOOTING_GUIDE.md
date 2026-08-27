# Troubleshooting Guide — SpectroCloud Support Bundles

This guide gives the context needed to effectively troubleshoot SpectroCloud support bundles.
Reference this document at the start of any support bundle analysis session.

---

## Bundle Types

There are two distinct bundle types with different scopes:

| Aspect | Edge Cluster Bundle | Infrastructure (Infra) Bundle |
|---|---|---|
| **Script** | `support-bundle-edge.sh` | `support-bundle-infra.sh` |
| **Naming** | `<hostname>-YYYY-MM-DD_HH_MM_SS/` | `<cluster-name>-YYYY-MM-DD_HH_MM_SS/` |
| **Scope** | Host-level OS + Kubernetes cluster | Kubernetes cluster only |
| **OS/journald logs** | Yes | No |
| **Network config** | Yes | No |
| **Edge-specific files** | Yes (`/oem`, `/run/stylus`, cloud-config) | No |
| **Container runtime logs** | Yes (crictl) | No |
| **K8s resources** | Yes | Yes |
| **Pod logs** | Yes | Yes |
| **Distro detection** | Yes (k3s, rke2, kubeadm, Canonical) | No (cluster-agnostic) |

**How to tell them apart:** Edge bundles have `journald/`, `systeminfo/`, `networking/`, `oem/` directories at the root. Infra bundles have only `k8s/` (plus `console.log` and `.support-bundle`).

---

## Edge Bundle — Directory Structure

```
<hostname>-YYYY-MM-DD_HH_MM_SS/
├── .support-bundle              # Bundle version (format: YYYYMMDD+githash)
├── console.log                  # Script execution log — check for collection errors
│
├── systeminfo/                  # Node OS information
│   ├── hostname                 # Node hostname
│   ├── os-release               # OS name and version
│   ├── cmdline                  # Kernel boot parameters
│   └── resolv.conf              # DNS configuration
│
├── journald/                    # Service logs (most important for edge debugging)
│   ├── dmesg                    # Kernel messages
│   ├── journal-boot             # Full boot journal
│   ├── stylus-operator.log      # Palette edge operator — primary log for pack/lifecycle issues
│   ├── stylus-agent.log         # Palette edge agent — registration, communication
│   ├── k3s.log                  # K3s runtime (if k3s distro)
│   ├── kubelet.log              # Kubelet
│   ├── containerd.log           # Container runtime
│   └── <50+ other services>     # systemd-timesyncd, cos-setup-boot, etc.
│
├── var/log/                     # OS log files (mirrors journald, sometimes more history)
│   ├── stylus-operator.log
│   ├── stylus-agent.log
│   └── store.log                # Stylus store/state service
│
├── networking/                  # Network configuration
│   ├── iptables                 # Firewall rules
│   ├── ip-route                 # Routing table
│   └── cni/                     # CNI plugin configs
│
├── oem/                         # OEM/Kairos configuration files
├── run/stylus/                  # Stylus runtime state files
├── run/immucore/                # Immucore (immutable OS) state
├── usr/local/cloud-config/      # Kairos cluster config (cluster.kairos.yaml — key file!)
├── opt/spectrocloud/            # Binary checksums
│
├── k8s/                         # Kubernetes cluster data
│   ├── cluster-info/            # cluster-info dump, API server resources, pod logs
│   ├── cluster-resources/       # kubectl get outputs (YAML) for all resource types
│   │   ├── nodes.yaml           # Node status, conditions, capacity
│   │   ├── namespaces.yaml      # All namespaces
│   │   ├── pods/                # Per-namespace pod status
│   │   ├── deployments/         # Per-namespace deployments
│   │   ├── events/              # Kubernetes events (warnings/errors)
│   │   └── <all other resource types>
│   ├── pod-logs/                # Current pod logs (from /var/log/pods)
│   ├── previous-pod-logs/       # Previous container logs (post-crash/restart)
│   └── metrics/                 # kubectl top nodes/pods output
│
├── k3s/                         # K3s-specific (if k3s distro)
│   ├── certs/                   # TLS certificates
│   └── crictl/logs/             # crictl container logs
│
├── etcd/                        # etcd status (if kubeadm distro)
└── helm/                        # Helm releases and repo info
```

---

## Infrastructure Bundle — Directory Structure

```
<cluster-name>-YYYY-MM-DD_HH_MM_SS/
├── .support-bundle              # Bundle version
├── console.log                  # Script execution log
└── k8s/
    ├── cluster-info/            # cluster-info dump, API resources, pod logs
    ├── cluster-resources/       # kubectl get outputs (YAML)
    │   ├── nodes.yaml
    │   ├── namespaces.yaml
    │   ├── pods/
    │   ├── deployments/
    │   ├── events/
    │   └── <all other resource types>
    ├── previous-pod-logs/       # Previous container logs
    └── metrics/                 # kubectl top output
```

---

## SpectroCloud Platform Overview

**Palette** is the SpectroCloud management platform. An edge deployment has:

- **Stylus Operator** — runs on the edge node, manages pack lifecycle (install/upgrade/delete)
- **Stylus Agent** — registers the node with the management plane, handles communication
- **Packs** — Helm chart-based applications deployed via cluster profiles
- **Cluster Profile** — defines what packs (OS, CNI, CSI, add-ons) are deployed on a cluster
- **Management Plane** — remote Palette SaaS that communicates with the agent

**Cluster types (by namespace presence):**
- Enterprise cluster: has `hubble-system` namespace
- PCG (Palette Cloud Gateway): has `jet-system` namespace with `spectro-cloud-driver` deployment
- Edge cluster: typically has `palette-system`, `spectro-system`, `spectro-task-*` namespaces

**Key system namespaces on edge:**
| Namespace | Purpose |
|---|---|
| `palette-system` | Palette webhooks and controllers |
| `spectro-system` | Stylus operator and core agents |
| `spectro-task-<id>` | Task execution for cluster operations |
| `cluster-<id>` | Cluster management agent |
| `cert-manager` | Certificate management |
| `kube-system` | Core Kubernetes components |

---

## Supported Kubernetes Distributions (Edge)

| Distribution | Indicator | Default KUBECONFIG |
|---|---|---|
| k3s | `k3s/` directory in bundle | `/run/kubeconfig` |
| rke2 | `rke2/` directory in bundle | `/etc/rancher/rke2/rke2.yaml` |
| kubeadm | `kubeadm/`, `etcd/` directories | `/etc/kubernetes/admin.conf` |
| Canonical k8s | `canonical-k8s/`, `dqlite/` directories | snap-managed path |

---

## Supported OS Platforms (Edge)

- **Kairos-based**: SLE Micro (SUSE), Ubuntu, openSUSE — identified by `kairos` in `/run/stylus` files and `cos-setup-boot` in journald
- **Non-Kairos**: Standard Linux installs using kubeadm/rke2

Kairos provides an **immutable OS** — config lives in `/oem/` and `/usr/local/cloud-config/`. The `cluster.kairos.yaml` is the primary cluster configuration source.

---

## Troubleshooting Methodology

### Step 1 — Orient Yourself

1. Read `.support-bundle` → confirm bundle version
2. Read `systeminfo/hostname`, `systeminfo/os-release` → OS and node identity
3. Check `usr/local/cloud-config/cluster.kairos.yaml` (edge) → K8s distro, network config, cluster ID
4. Read `console.log` → any collection errors (e.g., commands that failed to run)
5. Check bundle timestamp in directory name → when was data collected?

### Step 2 — Check Node and Cluster Health

1. `k8s/cluster-resources/nodes.yaml` → Node conditions (Ready, MemoryPressure, DiskPressure, PIDPressure)
2. `k8s/cluster-resources/pods/<namespace>.yaml` → Look for non-Running/non-Completed pods
3. `k8s/metrics/` → Resource pressure (high CPU/memory usage)
4. `k8s/cluster-resources/events/` → Kubernetes warnings and errors

**Pod states to investigate:** `CrashLoopBackOff`, `Error`, `Pending`, `OOMKilled`, `ImagePullBackOff`, `ErrImagePull`

### Step 3 — Investigate Stylus/Palette Issues

For pack deployment failures, registration issues, or upgrade problems:

1. **Primary:** `journald/stylus-operator.log` — pack pull, install, reconciliation errors
2. **Secondary:** `journald/stylus-agent.log` — registration, management plane comms
3. **Supporting:** `var/log/store.log` — state store operations

**Common patterns to grep for:**
```
"failed to"
"error"
"basic credential not found"    # Registry auth failure
"apiserver not ready"           # Startup race condition (usually transient)
"pack .* not found"             # Missing pack in cluster profile
"failed to get hostId"          # Node annotation issue
"failed to find.*token"         # Auth token missing
```

### Step 4 — Investigate Pod/Workload Issues

1. `k8s/cluster-resources/pods/<namespace>.yaml` → pod status, restartCount, lastState
2. `k8s/pod-logs/<namespace>/<pod>/` → current logs
3. `k8s/previous-pod-logs/<namespace>/<pod>/` → logs from before last crash/restart
4. `k8s/cluster-resources/events/<namespace>.yaml` → event history

### Step 5 — Investigate Node-Level Issues (Edge Only)

1. `journald/dmesg` → kernel/hardware errors, OOM kills
2. `journald/containerd.log` → container runtime errors
3. `journald/kubelet.log` → kubelet issues
4. `journald/k3s.log` (or rke2) → distribution-specific issues
5. `networking/iptables`, `networking/ip-route` → network policy/routing problems
6. `oem/` → OEM configuration issues

---

## Common Issues and Where to Find Them

| Symptom | Where to Look | What to Search For |
|---|---|---|
| Pack not installing | `journald/stylus-operator.log` | `"pack"`, `"failed to install"`, `"helm"` |
| Registry/image pull failure | `journald/stylus-operator.log` | `"credential"`, `"ImagePull"`, `"unauthorized"` |
| Node not registering | `journald/stylus-agent.log` | `"register"`, `"failed to"`, `"management plane"` |
| Pod crashlooping | `k8s/previous-pod-logs/` + events | Pod `lastState.terminated.reason` |
| OOM kill | `journald/dmesg` + pod status | `"oom"`, `"OOMKilled"` |
| Storage issues | `k8s/cluster-resources/pvc/` + pod events | `"FailedMount"`, `"bound"`, `"pending"` |
| Certificate errors | `journald/k3s.log`, cert-manager logs | `"certificate"`, `"tls"`, `"x509"` |
| DNS resolution | `systeminfo/resolv.conf` + coredns logs | DNS server config, coredns pod health |
| Upgrade failure | `journald/stylus-operator.log` + pack CSVs | `"upgrade"`, `"failed"` + check pack timeline |
| Startup/boot failure | `journald/journal-boot`, `journald/dmesg` | `"failed"`, `"error"` early in timeline |
| etcd issues | `etcd/` directory + k3s/rke2 logs | `"etcd"`, `"snapshot"`, `"leader"` |

---

## Key Configuration Files (Edge)

| File | Contents | Why It Matters |
|---|---|---|
| `usr/local/cloud-config/cluster.kairos.yaml` | K3s/cluster config, CNI, CIDR, OIDC, node IP | Primary cluster config source |
| `oem/*.yaml` | OEM/hardware profile | Device-specific settings |
| `run/stylus/*` | Stylus runtime state | Current operational state |
| `etc/containerd/config.toml` | Container runtime config | Registry mirrors, snapshotter settings |

---

## Cluster Configuration Quick Reference (from `cluster.kairos.yaml`)

Key fields to check:
- `k3s_args`: K3s startup flags (cluster-cidr, service-cidr, disable options)
- `k3s_args.flannel-backend`: CNI backend (e.g., `wireguard-native`)
- `k3s_args.node-ip`: Node's primary IP
- `k3s_args.tls-san`: Virtual/load-balancer IP for HA
- `k3s_args.oidc-issuer-url`: Management plane OIDC endpoint
- `k3s_args.token`: Cluster join token (treat as sensitive)

---

## Helm Releases

Located in `helm/` directory. Contains:
- Release names, namespaces, chart versions, status (deployed/failed/pending)
- Useful for confirming what version of a chart is actually installed vs. what's expected

---

## Notes on Log File Sizes

Large log files indicate high activity or issues:
- `stylus-operator.log` > 10 MB → likely repeated retry loops (registry failures, reconciliation errors)
- `stylus-agent.log` > 5 MB → communication issues with management plane
- `journalctl` > 100 MB → extended runtime or very verbose logging; use targeted greps

When log files are very large, grep for specific error patterns rather than reading linearly. Start from the **end** of the file for the most recent state.

---

## Infra Bundle — Additional Notes

Infra bundles lack OS-level data but follow the same `k8s/` structure as edge. When troubleshooting infra bundles:
- Focus entirely on pod health, events, and resource status
- Check `previous-pod-logs/` for any controller/operator crashes
- `k8s/cluster-resources/` contains the same resource types as edge
- No `journald/` or `systeminfo/` — OS-level issues cannot be diagnosed
