# Consolidated Support Bundle Collection Script

This Bash script (`support-bundle.sh`) collects diagnostic information from SpectroCloud environments. It consolidates the edge (`support-bundle-edge.sh`) and infrastructure (`support-bundle-infra.sh`) collectors into a single script that covers both scopes: host-level OS state and Kubernetes cluster state.

Collection is **capability-driven**: every collector is gated on the capabilities it actually needs (root, journald, a container runtime, a reachable API server, …) and the script **never aborts mid-run** — a partial bundle always beats no bundle. The only fatal errors are failure to create the temporary directory or write the archive.

## Quick Start

```bash
# On an edge host or cluster node: host + cluster bundle (requires root)
sudo bash support-bundle.sh

# From a jump host or laptop with kubectl access: cluster-only, no root needed
bash support-bundle.sh

# Cluster-only bundle on a cluster node (no root needed)
bash support-bundle.sh -H

# Host-only bundle (no Kubernetes collection)
sudo bash support-bundle.sh -K
```

## Prerequisites

* **Host collection** (automatic on edge hosts and cluster nodes, see [Host Scope](#host-scope)): run as root (`sudo`). Use `-H` for a cluster-only bundle that does not require root.
* **Kubernetes collection** (default): `kubectl` access to the cluster. The kubeconfig is resolved automatically (see below) or can be passed explicitly with `-k`.
* All other tools (`journalctl`, `crictl`, `chronyc`, `etcdctl`, `helm`, GPU tooling, …) are optional — collectors that need a missing tool are recorded as `SKIP` and the run continues.

## Available Flags

All flags are optional:

| Flag | Description | Example |
|------|-------------|---------|
| `-d` | Output directory for temporary storage and .tar.gz archive | `-d /var/tmp` |
| `-K` | Skip all Kubernetes collection (host-only bundle) | `-K` |
| `-H` | Skip all host collection (cluster-only bundle; no root required) | `-H` |
| `-A` | Collect host data even when this machine is not detected as a cluster node | `-A` |
| `-q` | Suppress per-resource progress output, keep the summary | `-q` |
| `-v` | Print the support bundle version and exit | `-v` |
| `-s` | Start day of journald log collection (days before now) | `-s 7` |
| `-e` | End day of journald log collection (days before now) | `-e 5` |
| `-S` | Start date of journald log collection | `-S 2024-01-01` |
| `-E` | End date of journald log collection | `-E 2024-01-01` |
| `-l` | Number of log lines to collect from journald/crictl logs | `-l 500000` |
| `-j` | Additional journald logs to collect | `-j cloud-init,systemd-resolved` |
| `-k` | Path to an explicit kubeconfig | `-k /etc/kubernetes/admin.conf` |
| `-n` | Additional namespaces to collect | `-n hello-universe,hello-world` |
| `-r` | Additional namespace scoped resources | `-r certificates.cert-manager.io` |
| `-R` | Additional cluster scoped resources | `-R clusterissuers.cert-manager.io` |

## Host Scope

Host collection is decided automatically, so the same command works on a node and on a jump host:

| Detected role | How it is detected | Host collection |
|---------------|--------------------|-----------------|
| `edge` | `/oem`, `/run/stylus`, `/etc/spectro/environment`, or the agent-mode state file | Yes |
| `capi-node` | A Cluster API marker (see below) | Yes |
| `k8s-node` | `/etc/kubernetes/kubelet.conf`, `/var/lib/kubelet/config.yaml`, rke2/k3s/Canonical agent dirs, or an active kubelet/k3s/rke2 unit | Yes |
| `none` | None of the above (jump host, laptop) | No; cluster-only bundle, root not required |

`-H` forces host collection off and `-A` forces it on. The detected role and the markers behind it are written to `.support-bundle`.

**Cluster API nodes** (MAAS, vSphere, AWS and other IaaS clusters bootstrapped by the CAPI kubeadm provider) are detected from any one of:

1. `/run/cluster-api/bootstrap-success.complete`: CAPI's bootstrap sentinel. `/run` is tmpfs, so it is gone after the first reboot.
2. `--register-with-taints=node.cluster.x-k8s.io/uninitialized` in `/var/lib/kubelet/kubeadm-flags.env`: persistent, but present on workers only.
3. `bootstrap-success.complete` in `/var/lib/cloud/instances/*/user-data.txt`: persistent, control planes included; readable by root only.
4. The node's `cluster.x-k8s.io/machine` annotation, read through the API when a kubeconfig is available: covers nodes whose on-disk markers are gone or were never written (for example Ignition-bootstrapped nodes).

Edge hosts bootstrap through stylus and `/opt/kubeadm` and carry none of these markers.

## Kubeconfig Resolution

The first readable entry wins; resolution is never fatal:

1. `-k <path>` flag
2. `$KUBECONFIG` environment variable
3. `/run/kubeconfig`
4. `/etc/kubernetes/admin.conf`
5. `$HOME/.kube/config`
6. The invoking user's `~/.kube/config` when running under `sudo`
7. `/etc/rancher/rke2/rke2.yaml`, `/etc/rancher/k3s/k3s.yaml`, `/var/snap/k8s/current/credentials/admin.conf`

If none is found (or the API server is unreachable within a 10s probe), Kubernetes collection is recorded as `SKIP` and the rest of the bundle is still produced. The selected kubeconfig's context and API server are logged and recorded in the summary, so a wrong current context on a jump host is easy to spot.

## Collection Summary

Every collector reports its outcome into `collection-summary.txt` inside the bundle (and to stdout at the end of the run):

| Status | Meaning |
|--------|---------|
| `OK` | Collector ran successfully |
| `SKIP` | Precondition absent (tool not installed, not an edge host, scope disabled, …) |
| `FAIL` | Collector ran and errored |
| `DENIED` | Blocked by RBAC |

## RBAC Coverage (advisory)

Before Kubernetes collection, the script checks `kubectl auth can-i` for the required cluster-scoped resources and pod access per targeted namespace, and writes the result table to `namespace-coverage.txt` inside the bundle.

Unlike previous script versions, **insufficient RBAC never aborts the run**: denied namespaces are pruned from collection, recorded as `DENIED`, and remediation guidance (a minimal ClusterRole snippet) is printed — then collection continues with what is accessible.

## Output

Bundle naming and archive location match the legacy scripts:

| Run scope | Bundle name | Archive location |
|-----------|-------------|------------------|
| Host in scope (detected node or `-A`) | `<hostname>-<timestamp>.tar.gz` | Temporary base directory (`mktemp -d`, typically under `/tmp`; `-d <dir>` relocates it) — edge hosts often have read-only partitions, so the archive is never written to the current working directory |
| Cluster-only (`-H`, or no node detected) | `<cluster-name>-<timestamp>.tar.gz` | `-d <dir>` if given, else the current working directory, else the temporary base directory if neither is writable |

Every bundle contains `console.log` (the full run transcript), `.support-bundle` (version, scopes, detected capabilities), and `collection-summary.txt`.

## Collected Information

Identical in scope to the union of the two legacy scripts:

* **Host tier** (requires root; runs on detected nodes or with `-A`, skipped with `-H`): system info, chronyd/time sync, networking (iptables/nft/ip/ss/CNI), `/var/log` and `/var/log/spectrocloud`, journald units (including previous-boot kernel log), storage state (block devices, LVM, NVMe SMART, device-mapper), GPU state (AMD ROCm + NVIDIA, with `kubectl exec` fallbacks into operator pods), edge agent files (`/oem`, `/run/stylus`, cloud-config, installer logs, bundle checksums), container runtime (crictl), helm releases, and on Cluster API nodes the bootstrap state (`capi/`: markers found, `kubeadm-flags.env`, `cloud-init status`, and which CAPI markers the user-data contains; the user-data itself is never copied because it carries the join token).
* **Kubernetes tier** (skipped with `-K`): cluster info and dump, cluster- and namespace-scoped resources, custom resources, helm release secrets, metrics, previous pod logs, and — on Enterprise/PCG clusters — MongoDB replica set status, per-pod disk usage, and database/collection sizes. When Cluster API CRDs are installed, `k8s/capi/` adds a Node-to-Machine map, summaries and conditions for Cluster, MachineDeployment, MachineSet, Machine, KubeadmControlPlane, MachineHealthCheck and MachinePool objects, and the infrastructure provider's objects.
* **Distro tier** (host + detected distribution): kubeadm manifests/certs/etcd, k3s/rke2 pod logs and certs, Canonical snap k8s files/dqlite state.

Secrets are not collected, except helm release secrets for the spectro namespaces. Certificates are captured parsed (`openssl x509 -text -noout`), never as raw keys.

## Environment Variables

* `KUBECONFIG`: Path to the Kubernetes configuration file (see resolution order above)
* `DEV`: When set, bypasses the root requirement (development/testing only)

## Relationship to the Legacy Scripts

`support-bundle-edge.sh` and `support-bundle-infra.sh` remain available as fallbacks until this script is widely adopted:

* `sudo bash support-bundle.sh` on a node ≈ `support-bundle-edge.sh` (full scope, root required)
* `bash support-bundle.sh` from a jump host, or `-H` on a node ≈ `support-bundle-infra.sh` (cluster-only, no root)

Behavioral differences vs. the legacy scripts:

* Insufficient RBAC and a missing/unset `KUBECONFIG` no longer abort the run (previously fatal in both scripts).
* Every run produces `collection-summary.txt` and, when a cluster is reachable, `namespace-coverage.txt`.
* Host data is collected only on edge hosts and cluster nodes; run from a jump host, the bundle is cluster-only and does not describe the jump host.

Bundle naming and archive locations are unchanged from the legacy scripts (see [Output](#output)).
