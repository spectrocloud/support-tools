# Palette Controller Profiling Collection

`collect-pprof.sh` gathers Go pprof profiles, execution traces, controller metrics, and pod/deployment context from Palette's control-plane components on a workload cluster, and bundles everything into a single tarball to attach to a Palette Support ticket.

Palette Support may ask you to run this when investigating a CPU spike, memory growth, or a slow reconciliation issue on a workload cluster's `palette-controller-manager` or `cluster-management-agent`.

---

## Which components does this cover?

**Only two components on a workload cluster expose Go pprof profiling behind the `PROFILING=enable` environment variable:**

| Namespace | Deployment | Containers profiled |
|---|---|---|
| `cluster-<uid>` | `palette-controller-manager` | `manager` (:8080), `atop-manager` (:8082) |
| `cluster-<uid>` | `cluster-management-agent` | `cluster-management-agent` (:8082, BasicAuth) |

**Everything else — Hubble services, CAPI infrastructure providers (CAPA/CAPZ/CAPV/…), cert-manager, and any user workload — is out of scope for this script.** They do not honour the `PROFILING` env var, and Palette Support will not ask you to profile them. If Support needs data from those, they will provide a different procedure.

---

## Prerequisites

The script is designed to run in a bare shell on any machine that can reach your Palette workload cluster's API server:

| | |
|---|---|
| **Access** | A `kubeconfig` for the workload cluster with permission to read pods, read the `palette-agent-debug-server-creds` Secret, set env on the two Deployments above, and `port-forward` into their pods. |
| **Tools** | `bash` 3.2+, `kubectl`, `curl`, `tar`, plus standard POSIX userland (`awk`, `sed`, `grep`, `tr`, `wc`, `find`, `mktemp`, `date`, `cp`, `id`, `uname`). All checked up front — the script fails in the first second if any are missing, rather than mid-collection. No `go` toolchain, no `python3`, no `base64`. Works on Linux and macOS. |
| **Network** | Whatever your `kubectl port-forward` normally traverses (usually 443 to the cluster's API server). |

---

## Quick start

Download the script from either URL, point `kubectl` at the affected workload cluster, and run it:

```bash
# Using GitHub URL
curl -sSLO https://raw.githubusercontent.com/spectrocloud/support-tools/main/pprof/collect-pprof.sh
chmod +x collect-pprof.sh

export KUBECONFIG=/path/to/workload-cluster.kubeconfig
./collect-pprof.sh
```

The script prints the tarball path when it finishes — attach that `pprof-cluster-<uid>-<timestamp>.tar.gz` to your Palette Support ticket.

Everything else goes to stderr, so `TARBALL=$(./collect-pprof.sh)` captures just the path.

---

## ⚠️ Impact — read this before you run it

`PROFILING=enable` is set on the Deployment's pod template, so **enabling it triggers a rolling restart** of the pod. On the workload cluster this means:

- Cluster reconciliation pauses briefly while the pod rolls (typically under a minute).
- Any profile captured immediately after the restart measures **startup**, not the steady state that's actually of interest.

For the second reason, the recommended workflow is two-phase — enable first, wait for the workload to re-establish, then collect:

```bash
# Phase 1: enable profiling. The pod restarts now. Exits immediately.
./collect-pprof.sh -P

# ... let the cluster run for at least a few minutes so whatever Support is
#     investigating has time to re-appear on the newly started pod ...

# Phase 2: collect. No further restart.
./collect-pprof.sh
```

If profiling is already enabled when the script starts, **nothing restarts** and one call is enough — the two-phase workflow is only needed when profiling has to be turned on first.

By default the script **restores whatever state it found**. If it enabled profiling, it disables it again on exit — including if you Ctrl-C or the collection fails partway. Nothing to clean up by hand.

| Situation | Flags | On exit | Restarts |
|---|---|---|---|
| Profiling was off before you ran it | *(default)* | disabled — undoes its own change | 2 |
| Profiling was already on | *(default)* | left on — the script didn't enable it, so it doesn't revoke it | 0 |
| Profiling was already on | `-D` | disabled unconditionally | 1 |
| Profiling was off | `-k` | left on | 1 |
| Profiling was off | `-P` | left on by design — you'll come back and collect | 1 |

---

## Options

```
-d LIST       Deployments to profile (comma-separated). Default: BOTH
                palette-controller-manager AND cluster-management-agent.
                -d cluster-management-agent      # cluster-management-agent only
                -d palette-controller-manager    # palette-controller-manager only
-n NAMESPACE  Namespace. Default: auto-discovered.
-p POD        Explicit pod name (single deployment only; pair with -d).
-s SECONDS    CPU / trace sample window. Default 30.
-S LIST       Explicit sample offsets in seconds, e.g. -S 0,600,1800.
              "0" = single sample.
-c            CURRENT STATE ONLY: one sample, no restart, no waiting.
              Use this when profiling is already on and you want a
              single as-found snapshot.
-P            PREPARE ONLY: enable profiling and exit. Phase 1 above.
-w SECONDS    Legacy settle delay before first sample. Default 0.
-o DIR        Output directory for the tarball. Default: current directory.
-e MODE       Enable profiling: auto (only if unset) | yes | no. Default auto.
-k            Keep profiling enabled after collection.
-D            Always disable profiling on exit, even if it was already on.
-h            Full help.
```

Every flag also has an environment-variable twin (`DEPLOYS`, `NS`, `CPU_SECONDS`, `SAMPLE_SCHEDULE`, …). Run `./collect-pprof.sh -h` for the complete list.

### Sample schedule — chosen for you

If you pass neither `-S` nor `-c`, the schedule is picked automatically:

| When | Schedule | Why |
|---|---|---|
| The script had to enable profiling (`t=0` is a real cold start) | `0, 300, 900` seconds | Three points let Support see whether load **decays** (warm-up) or **stays flat** (real baseline). One sample cannot distinguish those. |
| Profiling was already on | Single sample | Offsets on an already-warm process would just be "time since the script started" — one honest sample is better. |

Every sample is stamped with the **measured container age** so Support can validate the data regardless of how the schedule was chosen.

---

## What's in the tarball

```
pprof-cluster-<uid>-<timestamp>/
  README.txt                   summary + validity verdict
  SAMPLES.txt                  per-sample offsets and measured container age
  sample-<offset>/             one full profile set per sample point
    manager-*.pb.gz            heap, allocs, goroutine, threadcreate, block,
    atop-manager-*.pb.gz       mutex, cpu (30s), execution trace, /metrics
    cma-*.pb.gz                (twice, 60s apart)
    pod-top.txt                4 x `kubectl top pod` samples 15s apart
  palette-controller-manager/  pod.yaml, deployment.yaml, pod-describe,
                               logs-manager.txt, logs-atop-manager.txt
  cluster-management-agent/    pod.yaml, deployment.yaml, pod-describe,
                               logs-cluster-management-agent.txt
  packs-t0.yaml / packs-t1.yaml   namespace Pack CRs, 10s apart
  FAILURES.txt                 present only if a fetch failed
```

**Please review the bundle before attaching it externally.** The pod and deployment manifests carry environment variables, image references, and secret names for your cluster. The logs contain whatever the controller logged during the collection window. If any of that is sensitive to your organization, redact it before sending — or share the bundle directly through the Support ticket, which is not public.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: kubectl not found in PATH` (or similar) | A required tool is missing. | Install the missing tool. The script names it and exits before doing anything. |
| `ERROR: KUBECONFIG is not set or the cluster is unreachable` | `kubectl` cannot talk to the cluster. | `export KUBECONFIG=...` to a valid file for the workload cluster and confirm with `kubectl get nodes`. |
| `no palette-controller-manager in <ns>` | The kubeconfig points at a management cluster or the wrong workload cluster. | Confirm the target with `kubectl config current-context` and switch to the workload cluster you want to profile. |
| `-p/POD overrides a single pod, but 2 deployments are active` | You passed `-p` without narrowing to one deployment. | Pair `-p` with `-d palette-controller-manager` (or `-d cluster-management-agent`). |
| `[<dep>] timed out after 120s waiting for a Ready pod carrying PROFILING=enable` | The rollout is stuck (image pull, admission webhook, resource pressure). | `kubectl -n <ns> rollout status deployment/<dep>` and `kubectl -n <ns> describe pod ...` to see why. |
| `cma/debug/pprof/mutex http=404` in `FAILURES.txt` | Known limitation — `cluster-management-agent` doesn't currently expose the mutex profile. | Nothing you need to do; Support already knows. The rest of the bundle is unaffected. |
| Bundle name reports "COLD START" | The youngest container has been running less than 2 minutes. | If you used `-P` first and waited, this shouldn't happen — check that the workload had time to re-establish. Otherwise re-run after leaving the pod alone for a few minutes. |

---

## Support

For issues, questions, or contributions:

- Open an issue in this repository
- Contact Spectro Cloud Support
