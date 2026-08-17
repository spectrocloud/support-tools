# Consolidated Support Bundle Collection Script

This Bash script (`support-bundle.sh`) collects diagnostic information from SpectroCloud environments. It consolidates the edge (`support-bundle-edge.sh`) and infrastructure (`support-bundle-infra.sh`) collectors into a single script that covers both scopes: host-level OS state and Kubernetes cluster state.

Collection is **capability-driven**: every collector is gated on the capabilities it actually needs (root, journald, a container runtime, a reachable API server, …) and the script **never aborts mid-run** — a partial bundle always beats no bundle. The only fatal errors are failure to create the temporary directory or write the archive.

## Quick Start

```bash
# Full bundle on an edge or cluster host (host collection requires root)
sudo bash support-bundle.sh

# Cluster-only bundle from any machine with kubectl access (no root needed)
bash support-bundle.sh -H

# Host-only bundle (no Kubernetes collection)
sudo bash support-bundle.sh -K
```

## Prerequisites

* **Host collection** (default): run as root (`sudo`). Use `-H` for a cluster-only bundle that does not require root.
* **Kubernetes collection** (default): `kubectl` access to the cluster. The kubeconfig is resolved automatically (see below) or can be passed explicitly with `-k`.
* All other tools (`journalctl`, `crictl`, `chronyc`, `etcdctl`, `helm`, GPU tooling, …) are optional — collectors that need a missing tool are recorded as `SKIP` and the run continues.

## Available Flags

All flags are optional:

| Flag | Description | Example |
|------|-------------|---------|
| `-d` | Output directory for temporary storage and .tar.gz archive | `-d /var/tmp` |
| `-K` | Skip all Kubernetes collection (host-only bundle) | `-K` |
| `-H` | Skip all host collection (cluster-only bundle; no root required) | `-H` |
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

## Kubeconfig Resolution

The first readable entry wins; resolution is never fatal:

1. `-k <path>` flag
2. `$KUBECONFIG` environment variable
3. `/run/kubeconfig`
4. `/etc/kubernetes/admin.conf`
5. `$HOME/.kube/config`
6. The invoking user's `~/.kube/config` when running under `sudo`
7. `/etc/rancher/rke2/rke2.yaml`, `/etc/rancher/k3s/k3s.yaml`, `/var/snap/k8s/current/credentials/admin.conf`

If none is found (or the API server is unreachable within a 10s probe), Kubernetes collection is recorded as `SKIP` and the rest of the bundle is still produced.

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

The script creates a compressed tarball named:

* `<cluster-name>-<hostname>-<timestamp>.tar.gz` when a cluster was reachable
* `<hostname>-<timestamp>.tar.gz` otherwise

The archive is written to the **current working directory** by default, to `-d <dir>` when given, and to the temporary base directory as a last resort if neither is writable. Every bundle contains `console.log` (the full run transcript), `.support-bundle` (version, scopes, detected capabilities), and `collection-summary.txt`.

## Collected Information

Identical in scope to the union of the two legacy scripts:

* **Host tier** (requires root; skipped with `-H`): system info, chronyd/time sync, networking (iptables/nft/ip/ss/CNI), `/var/log` and `/var/log/spectrocloud`, journald units (including previous-boot kernel log), storage state (block devices, LVM, NVMe SMART, device-mapper), GPU state (AMD ROCm + NVIDIA, with `kubectl exec` fallbacks into operator pods), edge agent files (`/oem`, `/run/stylus`, cloud-config, installer logs, bundle checksums), container runtime (crictl), and helm releases.
* **Kubernetes tier** (skipped with `-K`): cluster info and dump, cluster- and namespace-scoped resources, custom resources, helm release secrets, metrics, previous pod logs, and — on Enterprise/PCG clusters — MongoDB replica set status, per-pod disk usage, and database/collection sizes.
* **Distro tier** (host + detected distribution): kubeadm manifests/certs/etcd, k3s/rke2 pod logs and certs, Canonical snap k8s files/dqlite state.

Secrets are not collected, except helm release secrets for the spectro namespaces. Certificates are captured parsed (`openssl x509 -text -noout`), never as raw keys.

## Environment Variables

* `KUBECONFIG`: Path to the Kubernetes configuration file (see resolution order above)
* `DEV`: When set, bypasses the root requirement (development/testing only)

## Relationship to the Legacy Scripts

`support-bundle-edge.sh` and `support-bundle-infra.sh` remain available as fallbacks until this script is widely adopted:

* `support-bundle.sh` ≈ `support-bundle-edge.sh` (full scope, root required)
* `support-bundle.sh -H` ≈ `support-bundle-infra.sh` (cluster-only, no root)

Behavioral differences vs. the legacy scripts:

* Insufficient RBAC and a missing/unset `KUBECONFIG` no longer abort the run (previously fatal in both scripts).
* The archive is written to the current working directory by default (the edge script wrote it to the temporary base directory).
* The bundle name includes the cluster name when available (previously edge used hostname only, infra used cluster name only).
* Every run produces `collection-summary.txt` and, when a cluster is reachable, `namespace-coverage.txt`.
