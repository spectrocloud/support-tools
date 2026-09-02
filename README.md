# support-tools

## support-bundle

## pprof

Profile collection for Palette control-plane components (`palette-controller-manager` and `cluster-management-agent`) on a workload cluster. Produces a single tarball to attach to a support ticket.

- **Script**: [`pprof/collect-pprof.sh`](pprof/collect-pprof.sh)
- **Documentation**: [`pprof/README.md`](pprof/README.md)
- **Quick Start**:
  ```bash
  # Using GitHub URL
  curl -sSLO https://raw.githubusercontent.com/spectrocloud/support-tools/main/pprof/collect-pprof.sh
  chmod +x collect-pprof.sh

  export KUBECONFIG=/path/to/workload-cluster.kubeconfig
  ./collect-pprof.sh
  ```

  Only `palette-controller-manager` and `cluster-management-agent` expose Go pprof endpoints via `PROFILING=enable`. Hubble services, CAPI providers, and other components are out of scope.
