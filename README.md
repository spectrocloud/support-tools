# support-tools

Diagnostic scripts for Spectro Cloud Palette environments. Each tool is self-contained, runs from a bare shell, and produces artifacts you attach to a Palette Support ticket.

## Table of contents

- [Support bundles](#support-bundles)
  - [Edge support bundle](#edge-support-bundle)
  - [Infrastructure support bundle](#infrastructure-support-bundle)
- [Palette controller profiling (pprof)](#palette-controller-profiling-pprof)
- [Support](#support)

---

## Support bundles

Log and state collection from Palette clusters and edge hosts. Full documentation lives in [`support-bundle/`](support-bundle/) — see [`support-bundle/README.md`](support-bundle/README.md).

### Edge support bundle

Collects system journals, `systemd` service state, `kubectl` cluster info, and Kubernetes resources from an edge host and the cluster running on it. Use this on the **host**, as `sudo`.

- **Script**: [`support-bundle/support-bundle-edge.sh`](support-bundle/support-bundle-edge.sh)
- **Documentation**: [`support-bundle/README-edge.md`](support-bundle/README-edge.md)
- **Prerequisites**: `sudo`, `journalctl`, `systemctl`, `kubectl`
- **Runs on**: Edge host (Linux)
- **Quick Start**:
  ```bash
  # Official SpectroCloud URL
  curl -sSL https://software.spectrocloud.com/scripts/support-bundle-edge.sh -o support-bundle-edge.sh
  sudo bash support-bundle-edge.sh

  # GitHub URL
  curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-edge.sh -o support-bundle-edge.sh
  sudo bash support-bundle-edge.sh
  ```
- **Advanced**: extra namespaces, resources, or `journalctl` units via `-n`, `-r`, `-R`, `-j` flags. See the edge README for the full list.

### Infrastructure support bundle

Collects cluster state, Cluster API (CAPI) objects, and Palette resources from a Kubernetes infrastructure cluster. Use this against a Palette **management** or **workload** cluster's kubeconfig.

- **Script**: [`support-bundle/support-bundle-infra.sh`](support-bundle/support-bundle-infra.sh)
- **Documentation**: [`support-bundle/README-infra.md`](support-bundle/README-infra.md)
- **Prerequisites**: `kubectl` with cluster access
- **Runs on**: Any workstation that can reach the cluster's API server
- **Quick Start**:
  ```bash
  # Official SpectroCloud URL
  curl -sSL https://software.spectrocloud.com/scripts/support-bundle-infra.sh -o support-bundle-infra.sh
  bash support-bundle-infra.sh

  # GitHub URL
  curl -sSL https://raw.githubusercontent.com/spectrocloud/support-tools/main/support-bundle/support-bundle-infra.sh -o support-bundle-infra.sh
  bash support-bundle-infra.sh
  ```
- **Advanced**: extra namespaces and resources via `-n`, `-r`, `-R` flags. See the infra README for the full list.

---

## Palette controller profiling (pprof)

Go pprof profiles, execution traces, `/metrics`, and pod/deployment context from Palette's control-plane components on a workload cluster. Produces a single tarball to attach to a support ticket.

**Scope — read this before running.** Only two Deployments on a workload cluster expose Go pprof profiling behind the `PROFILING=enable` environment variable: `palette-controller-manager` and `cluster-management-agent`. Hubble services, CAPI infrastructure providers (CAPA/CAPZ/CAPV/…), cert-manager, and user workloads are **out of scope** — they do not honour this environment variable, and this script does not attempt to profile them.

- **Script**: [`pprof/collect-pprof.sh`](pprof/collect-pprof.sh)
- **Documentation**: [`pprof/README.md`](pprof/README.md)
- **Prerequisites**: `bash` 3.2+, `kubectl`, `curl`, `tar`, standard POSIX userland. No `python3`, no `base64`. Runs on Linux and macOS.
- **Runs on**: Any workstation that can reach the workload cluster's API server
- **Quick Start**:
  ```bash
  # GitHub URL
  curl -sSLO https://raw.githubusercontent.com/spectrocloud/support-tools/main/pprof/collect-pprof.sh
  chmod +x collect-pprof.sh

  export KUBECONFIG=/path/to/workload-cluster.kubeconfig
  ./collect-pprof.sh
  ```
- **Impact**: enabling profiling triggers a rolling restart of the affected pod. See the pprof README for the recommended two-phase workflow (`-P` to enable, wait, then collect) that avoids measuring cold-start behaviour instead of steady state.

---

## Support

- Open an issue in this repository for bugs, questions, or contributions.
- Contact Spectro Cloud Support for help using these scripts on a specific cluster.
- Each script has its own detailed README linked above — flags, output layout, and troubleshooting live there.
