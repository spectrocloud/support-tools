#!/bin/bash
# Copyright 2026 Spectro Cloud
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# collect-pprof.sh -- collect Go pprof profiles + controller metrics from a
# Spectro Cloud controller and bundle them into a single tarball.
#
# ---------------------------------------------------------------------------
# READ THIS FIRST: enabling profiling RESTARTS the pod.
#
# The PROFILING=enable env var lives on the Deployment's pod template, so setting
# it rolls the pod. That destroys the exact state you usually want to profile --
# a long-running process with a slow leak or a hot reconcile loop -- and leaves
# you measuring startup instead.
#
# This has bitten a real investigation: all four collected bundles were taken 5-6s
# after container start. The 30s CPU window measured cold-start discovery, and
# labeled Prometheus series (workqueue_adds_total, controller_runtime_reconcile_*)
# had not been incremented yet so they were ABSENT from /metrics entirely -- the
# single most diagnostic signal for a hot-reconcile loop, silently missing.
#
# Hence two phases. Prefer them over a one-shot run:
#
#   Phase 1, once:   collect-pprof.sh -P          # enable + exit; pod restarts NOW
#   ... let the workload run and the symptom re-establish (hours is fine) ...
#   Phase 2, later:  collect-pprof.sh             # no restart, real baseline
#
# A one-shot run still works and will enable, wait SETTLE_SECONDS, then collect --
# but a settle is a mitigation, not a fix. If PROFILING is already on, nothing
# restarts and you get a clean read.
# ---------------------------------------------------------------------------

PPROF_VERSION=20260901

# ==== Targets ====
# PROFILING=enable is a shared Spectro convention, not palette-specific -- the
# same mechanism exists in palette (pkg/utils/https_pprof.go), ally
# (services/cluster-management-agent/service/pprof/https_pprof.go) and stylus
# (pkg/pprof/profiling_server.go). Only the container/port/auth differ, so the
# target is data, not hardcoded control flow.
#
# Format: <label>:<container>:<port>:<basic-auth-secret>:<probe-path>:<has-metrics>
#   label       name used in output filenames
#   container   container name (also the -c selector for `kubectl set env`)
#   port        pprof/metrics port inside the pod
#   secret      k8s secret holding BasicAuth creds; empty = plain HTTP
#   probe-path  path used for the readiness check (see below)
#   has-metrics yes|no -- whether this target serves Prometheus /metrics
#
# probe-path matters because the two are architecturally different:
#   palette  attaches pprof to the controller-runtime METRICS server, which
#            listens whether or not PROFILING is set -> /metrics always answers.
#   ally     runs a standalone pprof server that only starts under
#            PROFILING=enable, and serves NO /metrics at all -> probing /metrics
#            can never succeed, and probing anything with nothing listening kills
#            the port-forward ("error: lost connection to pod").
# Both components by default. A past regression involved palette-controller-manager AND
# cluster-management-agent, but the collector only ever did one, so ally's share
# had to be reasoned about instead of measured. Collecting both in ONE run also
# samples them at the SAME instants, which is what makes cross-component
# comparison meaningful. -d narrows to a specific deployment (comma-separated).
DEPLOYS_DEFAULT="palette-controller-manager,cluster-management-agent"
DEPLOYS="${DEPLOYS:-}"
TARGETS_PALETTE=("manager:manager:8080::metrics:yes" "atop-manager:atop-manager:8082::metrics:yes")
TARGETS_ALLY=("cma:cluster-management-agent:8082:palette-agent-debug-server-creds:debug/pprof/:no")
# kube-rbac-proxy is a sidecar and must never be touched; `--all` would set
# PROFILING on it pointlessly.
CONTAINER_SELECTOR="${CONTAINER_SELECTOR:-*manager}"

NS="${NS:-}"
POD="${POD:-}"
CPU_SECONDS="${CPU_SECONDS:-30}"
TRACE_SECONDS="${TRACE_SECONDS:-5}"
OUT_DIR="${OUT_DIR:-$PWD}"
ENABLE_PROFILING="${ENABLE_PROFILING:-auto}"   # auto | yes | no
KEEP_ENABLED="${KEEP_ENABLED:-no}"
FORCE_DISABLE="${FORCE_DISABLE:-no}"
PREPARE_ONLY="${PREPARE_ONLY:-no}"             # -P: enable + exit
# Multi-sample schedule: seconds from the start of collection at which to take a
# full sample set. Three points turn "is this a transient or sustained?" from an
# unanswerable question into a readable shape:
#   decaying 1327m -> 400m -> 200m  = warmup, do not cite the first number
#   flat     1327m -> 1330m -> 1325m = sustained, this is the real baseline
# One sample cannot distinguish those, which is how a real regression was misread.
# Set to a single "0" for a one-shot collection.
# Whether the schedule was chosen explicitly (env or -S). If not, it is selected
# automatically from whether this run had to enable profiling -- see
# select-schedule(). Keep this check BEFORE the default is applied.
if [ -n "${SAMPLE_SCHEDULE+x}" ]; then SAMPLE_SCHEDULE_SET=yes; else SAMPLE_SCHEDULE_SET=no; fi
SAMPLE_SCHEDULE="${SAMPLE_SCHEDULE:-}"
SCHEDULE_RESTARTED="${SCHEDULE_RESTARTED:-0,300,900}"   # used when WE restart the pod
SCHEDULE_ASFOUND="${SCHEDULE_ASFOUND:-0}"               # used when profiling was already on
CURRENT_ONLY="${CURRENT_ONLY:-no}"             # -c: force a single as-found sample
SETTLE_SECONDS="${SETTLE_SECONDS:-0}"          # legacy; prefer -S
MIN_AGE_WARN="${MIN_AGE_WARN:-120}"            # warn if container younger than this
RATE_GAP_SECONDS="${RATE_GAP_SECONDS:-60}"     # gap between the two metrics scrapes
TOP_SAMPLES="${TOP_SAMPLES:-4}"
TOP_GAP_SECONDS="${TOP_GAP_SECONDS:-15}"
MKTEMP_BASEDIR="${MKTEMP_BASEDIR:-/tmp/pprof-XXXXXXXX}"

TARGETS=()
PF_PIDS=()
PF_LABELS=()
TARGET_PORT_REMOTE=()
TMPDIR_PF=""
TMPDIR_BASE=""
PROFILING_WAS_SET=""
WE_RESTARTED=no
WE_ENABLED=no

# ==== Helpers ====
function timestamp() {
  date -u "+%Y-%m-%d %H:%M:%S"
}
function techo() {
  echo "$(timestamp): $*"
}
function twarn() {
  echo "$(timestamp): WARNING: $*" >&2
}
function tdie() {
  echo "$(timestamp): ERROR: $*" >&2
  exit 1
}

function help() {
  cat <<'HELP'
collect-pprof.sh -- collect Go pprof + controller metrics from a Spectro controller

Usage: collect-pprof.sh [options]

  -d LIST       Comma-separated deployments to profile. Default: BOTH
                palette-controller-manager and cluster-management-agent.
                A deployment that is not present in the namespace is skipped
                with a warning, not an error.
  -n NAMESPACE  Namespace. Default: auto-discovered from the deployment.
  -p POD        Pod name, overriding auto-discovery. Requires a single
                deployment -- pair it with -d.
  -s SECONDS    CPU/trace sample window. Default: 30.
  -S LIST       Comma-separated seconds at which to take each full sample set.
                Overrides the automatic choice below. "0" = single sample.
  -c            CURRENT STATE ONLY: one sample, now, no restart, no waiting.
                For when you already enabled profiling and are mid-experiment.

                With neither -S nor -c, the schedule is chosen automatically:
                  profiling was OFF -> we enable it, the pod restarts, so t=0 is a
                    genuine cold start: sample at 0,300,900 (cold / 5min / 15min).
                    Three points show whether the load decays or is sustained.
                  profiling ALREADY ON -> no restart, so offsets would just be
                    "time since this script started" on an already-warm process.
                    Collect ONE as-found sample instead of pretending otherwise.
                Every sample is stamped with the MEASURED container age either way.
  -w SECONDS    Legacy settle before the first sample. Default 0; prefer -S.
  -o DIR        Output directory for the tarball. Default: cwd.
  -e MODE       Enable PROFILING: auto (only if unset) | yes | no. Default: auto.
  -P            PREPARE ONLY: enable PROFILING, then exit. The pod restarts now;
                come back later and run without -P for a real baseline. This is
                the recommended workflow -- see the header comment.
  -k            Keep PROFILING enabled after collection.
  -D            Always disable PROFILING on exit, even if it was already on.
  -h            This help.

Environment overrides:
  DEPLOYS NS POD CPU_SECONDS TRACE_SECONDS OUT_DIR ENABLE_PROFILING KEEP_ENABLED
  FORCE_DISABLE PREPARE_ONLY SETTLE_SECONDS MIN_AGE_WARN RATE_GAP_SECONDS
  TOP_SAMPLES TOP_GAP_SECONDS CONTAINER_SELECTOR SAMPLE_SCHEDULE CURRENT_ONLY
  SCHEDULE_RESTARTED SCHEDULE_ASFOUND

Examples:
  collect-pprof.sh -P                       # phase 1: enable, pod restarts now
  collect-pprof.sh                          # phase 2: collect, no restart
  collect-pprof.sh -d cluster-management-agent   # ally only
  collect-pprof.sh -d palette-controller-manager # palette only
  collect-pprof.sh -c                            # both, single as-found sample
HELP
}

function is-kubeconfig-set() {
  kubectl cluster-info >/dev/null 2>&1
}

function check-prereqs() {
  # Fail here with a clear message rather than "command not found" halfway
  # through a 15-minute collection in a customer shell. `seq` and `base64` are
  # deliberately NOT in this list: both are non-POSIX and `base64 -d` is
  # GNU-only (BSD wants -D), so their uses were removed rather than guarded.
  for c in kubectl curl tar awk sed grep tr wc find mktemp date cp id uname; do
    command -v "$c" >/dev/null || tdie "$c not found in PATH"
  done
}

function dep_idx() { # dep_idx <deployment> -- echo its index in ACTIVE_DEPLOYS
  # READ-ONLY. It must not register anything: this is called as `i=$(dep_idx ...)`,
  # and command substitution runs in a subshell, so any array write here is
  # discarded and every caller would get index 0 -- which silently pointed all of
  # palette's port-forwards at the ally pod. ACTIVE_DEPLOYS is built in the parent
  # shell, so its position IS the index; no separate registry is needed.
  local d="$1" n
  n=0
  while [ "$n" -lt "${#ACTIVE_DEPLOYS[@]}" ]; do
    [ "${ACTIVE_DEPLOYS[$n]}" = "$d" ] && { echo "$n"; return 0; }
    n=$((n+1))
  done
  echo -1
  return 1
}

function dep_get() { # dep_get <deployment> <pod|enabled|was_set>
  local i; i=$(dep_idx "$1") || return 0
  case "$2" in
    pod)     echo "${DEP_POD_V[$i]:-}" ;;
    enabled) echo "${DEP_ENABLED_V[$i]:-no}" ;;
    was_set) echo "${DEP_WAS_SET_V[$i]:-no}" ;;
  esac
}

function dep_set() { # dep_set <deployment> <pod|enabled|was_set> <value>
  local i; i=$(dep_idx "$1") || tdie "internal error: unknown deployment '$1'"
  case "$2" in
    pod)     DEP_POD_V[$i]="$3" ;;
    enabled) DEP_ENABLED_V[$i]="$3" ;;
    was_set) DEP_WAS_SET_V[$i]="$3" ;;
  esac
}

function targets_for() { # targets_for <deployment> -- print its target specs
  case "$1" in
    palette-controller-manager) printf '%s\n' "${TARGETS_PALETTE[@]}" ;;
    cluster-management-agent)   printf '%s\n' "${TARGETS_ALLY[@]}" ;;
    *)  # Convention shared by ally and stylus: one container, same name, :8082.
        printf '%s\n' "$1:$1:8082::debug/pprof/:no" ;;
  esac
}

function selector_for() { # selector_for <deployment> -- the -c selector for `kubectl set env`
  case "$1" in
    # kube-rbac-proxy is a sidecar and must never be touched; --all would set
    # PROFILING on it pointlessly.
    palette-controller-manager) echo '*manager' ;;
    *) echo "$1" ;;
  esac
}

function detect-namespace() { # detect-namespace <deployment>
  local dep="$1" matches count
  [ -n "$NS" ] && return 0
  matches=$(kubectl get deployment -A \
    -o jsonpath="{range .items[?(@.metadata.name==\"$dep\")]}{.metadata.namespace}{\"\n\"}{end}" \
    | grep . || true)
  count=$(printf '%s' "$matches" | grep -c . || true)
  case "$count" in
    0) return 1 ;;
    1) NS="$matches"; techo "namespace: $NS" ;;
    *) techo "$dep found in $count namespaces:"; printf '  %s\n' $matches
       tdie "pass -n to choose one" ;;
  esac
}

function profiling-state() { # profiling-state <deployment>
  kubectl get "deployment/$1" -n "$NS" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{range .env[?(@.name=="PROFILING")]}{.value}{"\n"}{end}{end}' \
    2>/dev/null | grep -q enable && echo yes || echo no
}

function enable-profiling() { # enable-profiling <deployment>
  local dep="$1" sel was
  sel=$(selector_for "$dep")
  was=$(profiling-state "$dep")
  dep_set "$dep" was_set "$was"
  dep_set "$dep" enabled no
  if [ "$was" = yes ]; then
    techo "[$dep] PROFILING already enabled -- no restart needed"
    return 0
  fi
  if [ "$ENABLE_PROFILING" = no ]; then
    twarn "[$dep] PROFILING not enabled and -e no given; its pprof endpoints will not answer"
    return 0
  fi
  twarn "[$dep] enabling PROFILING RESTARTS the pod and destroys the state you want to profile."
  twarn "  Consider -P now, collect later."
  techo "[$dep] enabling PROFILING on containers matching '$sel'"
  kubectl set env "deployment/$dep" -n "$NS" -c "$sel" PROFILING=enable >/dev/null \
    || tdie "[$dep] failed to set PROFILING"
  dep_set "$dep" enabled yes
  WE_ENABLED=yes
  WE_RESTARTED=yes
  techo "[$dep] waiting for rollout"
  kubectl rollout status "deployment/$dep" -n "$NS" --timeout=5m >&2 \
    || tdie "[$dep] rollout did not complete"
}

function pods_matching() { # pods_matching <deployment>
  # kubectl jsonpath only -- NO python3. Customer environments cannot be assumed
  # to have python3, and a hard dependency here would make the collector
  # unusable in exactly the places it is most needed.
  #
  # Fields are '|'-delimited, NOT space-delimited: deletionTimestamp is usually
  # empty, and with whitespace splitting an empty middle field collapses and
  # shifts every later field, so a healthy pod parsed as "terminating".
  #
  # Emits: name|phase|ready|deletionTimestamp|profilingValues
  # profilingValues is the CONCATENATION across containers, so palette (two
  # containers both set) yields "enableenable" -- match with a substring test,
  # never equality.
  kubectl -n "$NS" get pod -o jsonpath="{range .items[*]}\
{.metadata.name}{\"|\"}\
{.status.phase}{\"|\"}\
{range .status.conditions[?(@.type==\"Ready\")]}{.status}{end}{\"|\"}\
{.metadata.deletionTimestamp}{\"|\"}\
{range .spec.containers[*]}{range .env[?(@.name==\"PROFILING\")]}{.value}{end}{end}\
{\"\n\"}{end}" 2>/dev/null \
    | awk -F'|' -v pre="$1-" 'index($1, pre)==1 {print}'
}

function pick_pod() { # pick_pod <deployment> <require-profiling yes|no>
  local dep="$1" want="$2" name phase ready deleting prof fallback=""
  while IFS='|' read -r name phase ready deleting prof; do
    [ -n "$name" ] || continue
    [ -n "$deleting" ] && continue           # terminating
    [ "$phase" = "Running" ] || continue
    if [ "$want" = yes ]; then
      case "$prof" in *enable*) ;; *) continue ;; esac
    fi
    if [ "$ready" = "True" ]; then echo "$name"; return 0; fi
    fallback="${fallback:-$name}"
  done < <(pods_matching "$dep")
  [ -n "$fallback" ] && { echo "$fallback"; return 0; }
  return 1
}

function detect-pod() { # detect-pod <deployment> -- echoes the pod name
  local dep="$1" pod="" deadline
  # An explicit -p wins over auto-detection. It is validated in the parent shell
  # (see the -p guards below the deployment scan), NOT here: detect-pod is called
  # as `pod=$(detect-pod ...)`, so a tdie in this function exits only the
  # subshell and the caller's `|| tdie` then overwrites the accurate message with
  # a misleading "no Running pod".
  if [ -n "$POD" ]; then
    echo "$POD"
    return 0
  fi
  # Whenever PROFILING is expected to be on -- whether WE set it or it was
  # already on the template -- insist on a pod that actually carries it.
  # `rollout status` can return before the old pod is marked for deletion, so a
  # plain "first Ready pod" pick returns the OLD pod, whose container has no
  # profiling server -> connection refused -> the port-forward dies. A rollout
  # can also be in flight for reasons unrelated to us (someone else enabled
  # profiling, an unrelated template edit), which is why was_set counts too.
  if [ "$(dep_get "$dep" enabled)" = yes ] || [ "$(dep_get "$dep" was_set)" = yes ]; then
    # Wait longer when we caused the restart; a rollout we did not start is
    # usually already settled, so do not stall a collection for two minutes.
    if [ "$(dep_get "$dep" enabled)" = yes ]; then deadline=$((SECONDS + 120)); else deadline=$((SECONDS + 30)); fi
    while [ "$SECONDS" -lt "$deadline" ]; do
      pod=$(pick_pod "$dep" yes) && [ -n "$pod" ] && break
      pod=""; sleep 3
    done
    if [ -z "$pod" ]; then
      # We caused it: no pod will ever carry PROFILING, so this is fatal.
      [ "$(dep_get "$dep" enabled)" = yes ] && return 2
      # We did not: fall back to any Running pod rather than refusing to
      # collect, but say so -- the fetches may 404 and the reader needs to know.
      twarn "[$dep] PROFILING is on the template but no Ready pod carries it after 30s; falling back to any Running pod (profiles may 404)"
      pod=$(pick_pod "$dep" no) || return 1
    fi
  else
    pod=$(pick_pod "$dep" no) || return 1
  fi
  [ -n "$pod" ] || return 1
  echo "$pod"
}

function select-schedule() {
  # Called AFTER enable-profiling, so WE_ENABLED is known.
  if [ "$CURRENT_ONLY" = yes ]; then
    SAMPLE_SCHEDULE="0"
    SCHEDULE_REASON="-c given: single as-found sample, no restart, no waiting"
  elif [ "$SAMPLE_SCHEDULE_SET" = yes ]; then
    SCHEDULE_REASON="explicitly set via -S/env"
  elif [ "$WE_ENABLED" = yes ]; then
    SAMPLE_SCHEDULE="$SCHEDULE_RESTARTED"
    SCHEDULE_REASON="we enabled profiling and a pod restarted, so t=0 is a real cold start"
  else
    SAMPLE_SCHEDULE="$SCHEDULE_ASFOUND"
    SCHEDULE_REASON="profiling was already enabled; no restart, so a multi-offset schedule would only re-measure the same warm state"
  fi
  # Guard: an empty schedule silently collects NOTHING and still archives a
  # bundle that looks successful. That happened once (a lost function definition
  # left SAMPLE_SCHEDULE unset) and produced a bundle with no profiles at all.
  [ -n "$SAMPLE_SCHEDULE" ] || tdie "internal error: sample schedule is empty -- refusing to produce an empty bundle"
  techo "sample schedule: ${SAMPLE_SCHEDULE}  (${SCHEDULE_REASON})"
  if [ "$WE_ENABLED" != yes ] && [ "$SAMPLE_SCHEDULE" != "0" ]; then
    twarn "no restart occurred, so these offsets are time since THIS RUN began --"
    twarn "  NOT time since process start. Read container_age in SAMPLES.txt."
  fi
}

function settle() {
  if [ "$WE_RESTARTED" != yes ]; then
    techo "no restart was needed -- collecting immediately (pod is already warm)"
    return 0
  fi
  if [ "$SETTLE_SECONDS" -le 0 ]; then
    twarn "we restarted the pod and SETTLE_SECONDS=0 -- results will be cold-start"
    return 0
  fi
  techo "settling ${SETTLE_SECONDS}s after the restart before collecting"
  local remaining=$SETTLE_SECONDS step
  while [ "$remaining" -gt 0 ]; do
    step=$(( remaining > 30 ? 30 : remaining ))
    sleep "$step"
    remaining=$(( remaining - step ))
    printf '    %ds remaining\r' "$remaining" >&2
  done
  printf '\n' >&2
}

function setup() {
  TMPDIR_BASE=$(mktemp -d "$MKTEMP_BASEDIR") || tdie "creating temporary directory failed"
  # pprof-<namespace>-<YYYYMMDDHHMMSS>.tar.gz -- namespace identifies the cluster,
  # timestamp is UTC. Deployment and pod names are deliberately NOT in the name:
  # a bundle can now hold several deployments, and README.txt / SAMPLES.txt carry
  # the per-target pod detail.
  LOGNAME="pprof-${NS}-$(date -u +'%Y%m%d%H%M%S')"
  TMPDIR="${TMPDIR_BASE}/${LOGNAME}"
  mkdir -p "$TMPDIR" || tdie "failed to create $TMPDIR"
  techo "collecting into $TMPDIR"
  echo "collect-pprof version: $PPROF_VERSION" > "$TMPDIR/.pprof-bundle"
}

# ==== Port-forward ====
function port_taken() { # port_taken <port> <used...>
  local want="$1"; shift
  local p
  for p in "$@"; do [ "$p" = "$want" ] && return 0; done
  return 1
}

function free_port() { # free_port <start> [<already-used>...] -- print an unused local port
  # Used ports come in as ARGUMENTS, not from a global array.
  #
  # This is called as `lport=$(free_port ...)`, and command substitution runs in a
  # SUBSHELL -- so appending to a global inside it is discarded, and every call
  # started from an empty "used" list. Two targets then got the same local port
  # and one port-forward pointed at the wrong pod: palette's atop-manager (:8082)
  # collided with ally's cma (:8082) and returned ally's 401.
  #
  # A direct-call unit test does NOT reproduce that, because without $( ) the
  # global does accumulate. Passing the list in is the only version that is
  # correct in the way it is actually used.
  # Probe upward with bash's /dev/tcp. Deliberately NOT python3: a customer
  # environment cannot be assumed to have it, and this is the one script that has
  # to run wherever the problem is.
  local port="$1"; shift
  local tries=0
  while [ "$tries" -lt 400 ]; do
    if ! port_taken "$port" "$@" && ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      echo "$port"; return 0
    fi
    port=$((port+1)); tries=$((tries+1))
  done
  tdie "could not find a free local port"
}

function start-port-forwards() {
  # Builds the flat per-target arrays across ALL selected deployments, so the
  # sample loop can hit every component at the same instant.
  local i=0 dep spec label container port secret probe hasmetrics lport pod
  TMPDIR_PF=$(mktemp -d /tmp/pf-XXXXXX)
  for dep in "${ACTIVE_DEPLOYS[@]}"; do
    pod="$(dep_get "$dep" pod)"
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      IFS=: read -r label container port secret probe hasmetrics <<<"$spec"
      lport=$(free_port $((18080 + i)) "${TARGET_PORTS[@]:-}")
      kubectl port-forward -n "$NS" "pod/$pod" "$lport:$port" >"$TMPDIR_PF/pf-$label.log" 2>&1 &
      PF_PIDS+=("$!")
      PF_LABELS+=("$label")
      TARGET_PORT_REMOTE+=("$port")
      TARGET_PORTS[$i]="$lport"
      TARGET_LABELS[$i]="$label"
      TARGET_SECRETS[$i]="$secret"
      TARGET_PROBES[$i]="${probe:-metrics}"
      TARGET_HASMETRICS[$i]="${hasmetrics:-yes}"
      TARGET_CONTAINERS[$i]="$container"
      TARGET_DEPLOY[$i]="$dep"
      TARGET_POD[$i]="$pod"
      techo "  target ${label}: localhost:${lport} -> ${pod}:${port} (probe /${probe:-metrics}, metrics=${hasmetrics:-yes})"
      i=$((i+1))
    done < <(targets_for "$dep")
  done
  [ "$i" -gt 0 ] || tdie "no targets to collect"

  techo "waiting for port-forwards ($i target(s))"
  local deadline=$((SECONDS + 30)) ok=0 j pf_log pf_phase
  while [ "$SECONDS" -lt "$deadline" ]; do
    ok=1
    for j in "${!TARGET_PORTS[@]}"; do
      curl -s -o /dev/null --max-time 3 "http://localhost:${TARGET_PORTS[$j]}/${TARGET_PROBES[$j]}" || ok=0
    done
    [ "$ok" = 1 ] && break
    for j in "${!PF_PIDS[@]}"; do
      kill -0 "${PF_PIDS[$j]}" 2>/dev/null && continue
      pf_log="$TMPDIR_PF/pf-${PF_LABELS[$j]}.log"
      twarn "port-forward for '${PF_LABELS[$j]}' exited. kubectl said:"
      sed 's/^/    /' "$pf_log" 2>/dev/null >&2
      pf_phase=$(kubectl -n "$NS" get pod "${TARGET_POD[$j]}" -o jsonpath='{.status.phase}' 2>/dev/null)
      if grep -q "connection refused" "$pf_log" 2>/dev/null; then
        # kubectl exits on the FIRST failed connection, so a refused target port
        # takes the whole forward down. Nothing is listening in the container.
        twarn "nothing is listening on port ${TARGET_PORT_REMOTE[$j]:-?} inside container '${PF_LABELS[$j]}'."
        if [ "$(dep_get "${TARGET_DEPLOY[$j]}" was_set)" != yes ] && [ "$(dep_get "${TARGET_DEPLOY[$j]}" enabled)" != yes ]; then
          tdie "PROFILING is not enabled on ${TARGET_DEPLOY[$j]}, whose profiling server only exists while PROFILING=enable -- nothing to collect. Re-run with '-e yes' (restarts the pod) or '-P' to enable now and collect later."
        fi
        tdie "PROFILING is enabled on ${TARGET_DEPLOY[$j]} but port ${TARGET_PORT_REMOTE[$j]:-?} refuses connections. The server may have failed to start, or this is not the post-rollout pod. Check: kubectl logs -n $NS ${TARGET_POD[$j]} -c ${PF_LABELS[$j]}"
      fi
      if [ "$pf_phase" != "Running" ]; then
        tdie "pod ${TARGET_POD[$j]} is '${pf_phase:-gone}' -- replaced or terminating. Re-run."
      fi
      tdie "pod ${TARGET_POD[$j]} is Running and the port is not refusing, so this is LOCAL: port already in use, or a kubectl/network problem."
    done
    sleep 1
  done
  [ "$ok" = 1 ] || twarn "port-forwards not all confirmed; some fetches may fail"
}

function auth_args() { # auth_args <secret-name>
  # ally's palette-agent-debug-server-creds stores USERNAME / PASSWORD in
  # UPPERCASE. Reading .data.username silently yields an empty value and the
  # request goes out with no -u, so every fetch comes back 401. Try both cases.
  local secret="$1" u p
  [ -z "$secret" ] && return 0
  # Decode via kubectl's own go-template base64decode, NOT `base64 -d`: base64
  # is not POSIX and -d is GNU-only (BSD/macOS wants -D), so piping through it
  # is a portability trap in a script that has to run in a bare customer shell.
  for k in USERNAME username; do
    u=$(kubectl -n "$NS" get secret "$secret" \
      -o "go-template={{if .data.$k}}{{index .data \"$k\" | base64decode}}{{end}}" 2>/dev/null)
    [ -n "$u" ] && break
  done
  for k in PASSWORD password; do
    p=$(kubectl -n "$NS" get secret "$secret" \
      -o "go-template={{if .data.$k}}{{index .data \"$k\" | base64decode}}{{end}}" 2>/dev/null)
    [ -n "$p" ] && break
  done
  if [ -z "$u" ]; then
    twarn "secret '$secret' has no USERNAME/username key -- requests will be unauthenticated (expect 401)"
    return 0
  fi
  printf -- '-u\n%s:%s\n' "$u" "$p"
}

function fetch() { # fetch <label> <lport> <secret> <path> <outfile>  (honours $SUB)
  local label=$1 port=$2 secret=$3 path=$4 out=$5 code
  local dir="$TMPDIR${SUB:+/$SUB}"
  mkdir -p "$dir"
  out="${SUB:+$SUB/}$out"
  local -a extra=()
  while IFS= read -r line; do [ -n "$line" ] && extra+=("$line"); done < <(auth_args "$secret")
  code=$(curl -s --max-time $((CPU_SECONDS + 60)) "${extra[@]}" \
           -o "$TMPDIR/$out" -w '%{http_code}' \
           "http://localhost:$port/$path" || echo 000)
  if [ "$code" = 200 ]; then
    printf '  %-38s %s bytes\n' "$out" "$(wc -c <"$TMPDIR/$out" | tr -d ' ')"
  else
    printf '  %-38s FAILED (http %s)\n' "$out" "$code"
    rm -f "$TMPDIR/$out"
    echo "$label/$path http=$code" >>"$TMPDIR/FAILURES.txt"
  fi
}

function container-age() { # container-age <target-index> -- seconds since container start
  # Read startedAt from the Kubernetes container status rather than
  # process_start_time_seconds off /metrics: not every target serves /metrics
  # (ally serves none), and this works uniformly for all of them.
  #
  # Arithmetic in the shell, NOT awk systime(): that is a GNU extension and
  # BSD/macOS awk fails with "calling undefined function systime".
  local idx="${1:-0}" started now
  started=$(kubectl -n "$NS" get pod "${TARGET_POD[$idx]}" \
    -o jsonpath="{.status.containerStatuses[?(@.name==\"${TARGET_CONTAINERS[$idx]}\")].state.running.startedAt}" \
    2>/dev/null)
  [ -n "$started" ] || return 0
  now=$(date -u +%s)
  # BSD date needs -j -f; GNU date needs -d. Try both.
  local st
  st=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$started" +%s 2>/dev/null) \
    || st=$(date -u -d "$started" +%s 2>/dev/null) || return 0
  echo $(( now - st ))
}

# ==== Collection ====
function collect-profiles() { # collect-profiles <subdir>
  local SUB="$1"
  techo "collecting instant profiles"
  local i prof
  for prof in allocs heap goroutine threadcreate block mutex; do
    for i in "${!TARGET_PORTS[@]}"; do
      fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
            "debug/pprof/$prof" "${TARGET_LABELS[$i]}-$prof.pb.gz"
    done
  done

  techo "collecting text profiles"
  for i in "${!TARGET_PORTS[@]}"; do
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'debug/pprof/cmdline' "${TARGET_LABELS[$i]}-cmdline.txt"
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'debug/pprof/goroutine?debug=2' "${TARGET_LABELS[$i]}-goroutine-stacks.txt"
    # The index lists the profiles the server actually offers, with sample counts.
    # Records what was available at collection time -- an endpoint missing here
    # (palette had no /debug/pprof/mutex route) is otherwise invisible, because a
    # request for it falls through to this index and returns 200.
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'debug/pprof/' "${TARGET_LABELS[$i]}-pprof-index.html"
    # expvar: runtime.MemStats + cmdline as ~4KB of JSON. Carries NumGC,
    # PauseTotalNs, NextGC and HeapObjects, none of which are in a heap profile;
    # across the sample schedule it gives a GC-pressure trend almost for free.
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'debug/vars' "${TARGET_LABELS[$i]}-expvars.json"
    # /debug/pprof/symbol is deliberately NOT collected: it resolves addresses for
    # a live pprof session, and .pb.gz profiles already carry their own symbols.
    # A GET returns "num_symbols: 1" and nothing usable offline.
  done

  # NOTE: never use a bare `wait` here -- the kubectl port-forward processes are
  # also children of this shell and never exit, so `wait` would block forever.
  techo "collecting CPU profile (${CPU_SECONDS}s, all targets in parallel)"
  local pids=()
  for i in "${!TARGET_PORTS[@]}"; do
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          "debug/pprof/profile?seconds=$CPU_SECONDS" "${TARGET_LABELS[$i]}-cpu.pb.gz" &
    pids+=("$!")
  done
  wait "${pids[@]}" 2>/dev/null || true

  techo "collecting execution trace (${TRACE_SECONDS}s, all targets in parallel)"
  pids=()
  for i in "${!TARGET_PORTS[@]}"; do
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          "debug/pprof/trace?seconds=$TRACE_SECONDS" "${TARGET_LABELS[$i]}-trace.out" &
    pids+=("$!")
  done
  wait "${pids[@]}" 2>/dev/null || true
}

function collect-metrics() { # collect-metrics <subdir>
  local SUB="$1"
  # TWO scrapes. A single scrape yields counters, which say nothing on their own:
  # the diagnostic signal for a hot-reconcile loop is the RATE of
  # workqueue_adds_total -- and NOT workqueue_depth, which reads ~0 during a full
  # loop because the workers drain the queue as fast as it fills (observed:
  # depth 0 while adds ran at ~112/min).
  #
  # Raw scrapes only. Deriving the rate table is analysis and belongs offline,
  # not in a script the customer runs against a production controller. Every
  # portability bug this script has had came from awk.
  local i
  # Skip targets with no /metrics endpoint entirely -- otherwise the fetches 404
  # and the RATE_GAP wait is spent for nothing. ally/cluster-management-agent
  # exposes no Prometheus metrics at all, so reconcile-rate analysis is simply
  # unavailable for it (worth its own eng bug).
  local any=no
  for i in "${!TARGET_PORTS[@]}"; do
    [ "${TARGET_HASMETRICS[$i]}" = yes ] && any=yes
  done
  if [ "$any" = no ]; then
    techo "no target exposes /metrics -- skipping metrics scrapes (and the ${RATE_GAP_SECONDS}s gap)"
    echo "no /metrics endpoint on: ${TARGET_LABELS[*]}" >"$TMPDIR/NO-METRICS.txt"
    return 0
  fi
  techo "collecting metrics scrape #1"
  for i in "${!TARGET_PORTS[@]}"; do
    [ "${TARGET_HASMETRICS[$i]}" = yes ] || continue
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'metrics' "${TARGET_LABELS[$i]}-metrics-t0.txt"
  done
  techo "waiting ${RATE_GAP_SECONDS}s for scrape #2 (counter deltas)"
  sleep "$RATE_GAP_SECONDS"
  techo "collecting metrics scrape #2"
  for i in "${!TARGET_PORTS[@]}"; do
    [ "${TARGET_HASMETRICS[$i]}" = yes ] || continue
    fetch "${TARGET_LABELS[$i]}" "${TARGET_PORTS[$i]}" "${TARGET_SECRETS[$i]}" \
          'metrics' "${TARGET_LABELS[$i]}-metrics-t1.txt"
    # Preserve the historical filename so existing greps/tooling still work.
    cp "$TMPDIR/${TARGET_LABELS[$i]}-metrics-t1.txt" \
       "$TMPDIR/${TARGET_LABELS[$i]}-metrics.txt" 2>/dev/null || true
  done
}

function collect-context() {
  techo "capturing cluster context"
  local dep pod c
  for dep in "${ACTIVE_DEPLOYS[@]}"; do
    pod="$(dep_get "$dep" pod)"
    mkdir -p "$TMPDIR/$dep"
    kubectl -n "$NS" get pod "$pod" -o yaml         >"$TMPDIR/$dep/pod.yaml"         2>/dev/null || true
    kubectl -n "$NS" get "deployment/$dep" -o yaml  >"$TMPDIR/$dep/deployment.yaml"  2>/dev/null || true
    kubectl -n "$NS" describe pod "$pod"            >"$TMPDIR/$dep/pod-describe.txt" 2>/dev/null || true
    for c in $(kubectl -n "$NS" get pod "$pod" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null); do
      kubectl -n "$NS" logs "$pod" -c "$c" --tail=2000 --limit-bytes=8000000 \
        >"$TMPDIR/$dep/logs-$c.txt" 2>/dev/null || true
    done
  done

  # Pack CRs are namespace-level, shared across deployments. Twice, WITH
  # managedFields: managedFields.time records when a field was last written, so a
  # controller rewriting its own watched object shows as a delta.
  if kubectl -n "$NS" get packs >/dev/null 2>&1; then
    kubectl -n "$NS" get packs --show-managed-fields -o yaml >"$TMPDIR/packs-t0.yaml" 2>/dev/null || true
    sleep 10
    kubectl -n "$NS" get packs --show-managed-fields -o yaml >"$TMPDIR/packs-t1.yaml" 2>/dev/null || true
    techo "captured packs-t0.yaml / packs-t1.yaml (10s apart)"
  fi
}

function write-readme() {
  local age_min="" verdict dep
  # Take the age from SAMPLES.txt, which recorded it at the instant each profile
  # was taken -- do NOT re-query the cluster here. write-readme runs minutes
  # after the last sample, and a container that restarts in that window (a crash
  # or an OOMKill, which is often the very thing under investigation) would make
  # this stamp a perfectly good bundle "COLD START -- DO NOT cite for magnitude".
  # The only age that describes the profiles is the one measured alongside them.
  age_min=$(awk 'NR>1 && $4 ~ /^[0-9]+$/ { if (m == "" || $4 < m) m = $4 } END { print m }' \
    "$TMPDIR/SAMPLES.txt" 2>/dev/null)
  if [ -n "$age_min" ] && [ "$age_min" -lt "$MIN_AGE_WARN" ]; then
    verdict="COLD START -- youngest container only ${age_min}s old (< ${MIN_AGE_WARN}s). CPU measures startup, NOT sustained baseline; workqueue/reconcile series may be absent because they are only registered on first increment. DO NOT cite for magnitude."
    twarn "$verdict"
  else
    verdict="ok -- youngest container ${age_min:-unknown}s old at collection"
  fi

  {
    printf 'Spectro controller pprof bundle\n'
    printf '===============================\n'
    printf 'collected       : %s (UTC)\n' "$(timestamp)"
    printf 'collect-pprof   : %s\n' "$PPROF_VERSION"
    printf 'namespace       : %s\n' "$NS"
    printf 'deployments     : %s\n' "${ACTIVE_DEPLOYS[*]}"
    printf 'targets         : %s\n' "${TARGET_LABELS[*]}"
    printf 'cpu window      : %ss\n' "$CPU_SECONDS"
    printf 'metrics gap     : %ss (scrape t0 -> t1)\n' "$RATE_GAP_SECONDS"
    printf 'we restarted    : %s\n' "$WE_RESTARTED"
    printf 'container age   : %ss (youngest) at collection\n' "${age_min:-unknown}"
    # A container that restarted during or before the run is itself a finding --
    # an OOMKill mid-collection is frequently the answer, and nothing else in the
    # bundle says so.
    for i in "${!TARGET_PORTS[@]}"; do
      rc=$(kubectl -n "$NS" get pod "${TARGET_POD[$i]}" \
        -o jsonpath="{.status.containerStatuses[?(@.name==\"${TARGET_CONTAINERS[$i]}\")].restartCount}" 2>/dev/null)
      [ -n "$rc" ] && [ "$rc" != 0 ] && printf 'RESTARTS        : %s has restarted %s time(s) -- see pod-describe.txt for lastState\n' \
        "${TARGET_LABELS[$i]}" "$rc"
    done
    printf 'VALIDITY        : %s\n' "$verdict"
    # id -un / uname -n, not whoami / hostname: the latter two are not POSIX and
    # are absent from some stripped-down container and appliance shells.
    printf 'collected by    : %s@%s\n\n' "$(id -un)" "$(uname -n)"
    printf 'per-target detail\n'
    printf '%-14s %-28s %-34s %s\n' LABEL DEPLOYMENT POD METRICS
    for i in "${!TARGET_PORTS[@]}"; do
      printf '%-14s %-28s %-34s %s\n' \
        "${TARGET_LABELS[$i]}" "${TARGET_DEPLOY[$i]}" "${TARGET_POD[$i]}" "${TARGET_HASMETRICS[$i]}"
    done
    printf '\nlayout\n'
    printf '  SAMPLES.txt              read first: sample offsets + measured container age\n'
    printf '  sample-<offset>/          one full profile set per target, per offset\n'
    for dep in "${ACTIVE_DEPLOYS[@]}"; do
      printf '  %s/  pod.yaml, deployment.yaml, logs-*.txt\n' "$dep"
    done
    printf '  packs-t0.yaml/-t1.yaml    namespace-level Pack CRs, 10s apart\n'
    printf '\nanalyze\n'
    printf '  go tool pprof -http=:8001 sample-0/%s-heap.pb.gz\n' "${TARGET_LABELS[0]}"
    printf '  go tool pprof -top -cum -diff_base sample-0/X-cpu.pb.gz sample-900/X-cpu.pb.gz\n'
    printf '  go tool trace sample-0/%s-trace.out\n' "${TARGET_LABELS[0]}"
    printf '\nreconcile rate (the signal for a hot loop; depth is NOT useful):\n'
    printf '  diff workqueue_adds_total / controller_runtime_reconcile_total between\n'
    printf '  *-metrics-t0.txt and *-metrics-t1.txt over the %ss gap.\n' "$RATE_GAP_SECONDS"
    printf '\nAny fetch that failed is listed in FAILURES.txt (absent if all succeeded).\n'
  } >"$TMPDIR/README.txt"
}

function archive() {
  # Never report success for a bundle with no profile data. A missing function
  # definition once left the schedule empty; the run archived cleanly and the
  # engineer only found out on analysis.
  local n
  n=$(find "$TMPDIR" -maxdepth 1 -type d -name 'sample-*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -eq 0 ]; then
    tdie "no sample-* directories were produced -- refusing to archive an empty bundle. This is a bug; report the console output."
  fi
  techo "creating archive ${LOGNAME}.tar.gz (${n} sample set(s))"
  mkdir -p "$OUT_DIR"
  tar -czf "${OUT_DIR}/${LOGNAME}.tar.gz" -C "$TMPDIR_BASE" "$LOGNAME" \
    || { techo "failed to create tar file"; return 1; }
  techo "bundle: ${OUT_DIR}/${LOGNAME}.tar.gz"
  techo "please upload it to the support ticket"
}

function cleanup() {
  local rc=$?
  for pid in "${PF_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  # PROFILING on exit. Restore what we found, and NEVER write to the Deployment
  # unless we are actually undoing our own change.
  #
  # The earlier logic keyed off "PROFILING_WAS_SET = no", which fired even when we
  # had enabled nothing -- so a run with `-e no` (user explicitly declining to
  # touch the deployment) still issued a `kubectl set env` against it and logged
  # "this restarts the pod". Harmless when the var was already absent, but it is a
  # write the user declined, and with -D it would roll a production pod for no
  # reason. Gate on WE_ENABLED instead of on the prior state.
  if [ -n "${NS:-}" ] && [ "$PREPARE_ONLY" = no ]; then
    local d sel
    for d in "${ACTIVE_DEPLOYS[@]:-}"; do
      [ -n "$d" ] || continue
      sel=$(selector_for "$d")
      if [ "$KEEP_ENABLED" = yes ]; then
        [ "$(dep_get "$d" enabled)" = yes ] && techo "[$d] leaving PROFILING enabled (-k)"
      elif [ "$(dep_get "$d" enabled)" = yes ]; then
        techo "[$d] disabling PROFILING we enabled (restarts the pod; not waiting)"
        kubectl set env "deployment/$d" -n "$NS" -c "$sel" PROFILING- >/dev/null 2>&1
      elif [ "$FORCE_DISABLE" = yes ] && [ "$(dep_get "$d" was_set)" = yes ]; then
        techo "[$d] disabling pre-existing PROFILING (-D). This restarts the pod."
        kubectl set env "deployment/$d" -n "$NS" -c "$sel" PROFILING- >/dev/null 2>&1
      elif [ "$(dep_get "$d" was_set)" = yes ]; then
        techo "[$d] leaving PROFILING enabled -- it was already on (-D forces off)"
      fi
    done
  fi
  [ -n "$TMPDIR_BASE" ] && rm -rf "$TMPDIR_BASE" >/dev/null 2>&1
  [ -n "$TMPDIR_PF" ] && rm -rf "$TMPDIR_PF" >/dev/null 2>&1
  exit "$rc"
}

# ==== Main ====
declare -a TARGET_PORTS TARGET_LABELS TARGET_SECRETS TARGET_PROBES TARGET_HASMETRICS TARGET_CONTAINERS
declare -a TARGET_DEPLOY TARGET_POD ACTIVE_DEPLOYS WANTED_DEPLOYS
# Parallel indexed arrays, NOT associative ones. macOS ships bash 3.2, where
# `declare -A` is an invalid option: the error goes to stderr and string
# subscripts then evaluate arithmetically to 0, so every key collapses onto index
# 0 and the last write wins. That silently pointed all of palette's port-forwards
# at the ally pod. Indexed arrays + dep_idx() work on bash 3.2 and 5.x alike.
declare -a DEP_NAMES DEP_POD_V DEP_ENABLED_V DEP_WAS_SET_V

while getopts 'd:n:p:s:w:o:e:S:cPkDh' opt; do
  case "$opt" in
    d) DEPLOYS="$OPTARG" ;;
    n) NS="$OPTARG" ;;
    p) POD="$OPTARG" ;;
    s) CPU_SECONDS="$OPTARG" ;;
    w) SETTLE_SECONDS="$OPTARG" ;;
    S) SAMPLE_SCHEDULE="$OPTARG"; SAMPLE_SCHEDULE_SET=yes ;;
    c) CURRENT_ONLY=yes ;;
    o) OUT_DIR="$OPTARG" ;;
    e) ENABLE_PROFILING="$OPTARG" ;;
    P) PREPARE_ONLY=yes ;;
    k) KEEP_ENABLED=yes ;;
    D) FORCE_DISABLE=yes ;;
    h) help; exit 0 ;;
    :) echo "option -$OPTARG requires an argument" >&2; help >&2; exit 2 ;;
    *) echo "unknown option -$OPTARG" >&2; help >&2; exit 2 ;;
  esac
done

case "$ENABLE_PROFILING" in auto|yes|no) ;; *) tdie "-e must be auto, yes or no" ;; esac
[[ "$CPU_SECONDS"    =~ ^[0-9]+$ ]] || tdie "-s must be an integer"
[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || tdie "-w must be an integer"

check-prereqs
is-kubeconfig-set || tdie "KUBECONFIG is not set or the cluster is unreachable"

[ -n "$DEPLOYS" ] || DEPLOYS="$DEPLOYS_DEFAULT"
IFS=',' read -r -a WANTED_DEPLOYS <<<"$DEPLOYS"
DEPLOYS_EXPLICIT=no
[ "$DEPLOYS" != "$DEPLOYS_DEFAULT" ] && DEPLOYS_EXPLICIT=yes

trap cleanup EXIT INT TERM

# Resolve namespace from the first deployment that exists, then keep only the
# deployments actually present. A missing one is a warning, not a failure: not
# every namespace runs both components.
for dep in "${WANTED_DEPLOYS[@]}"; do
  detect-namespace "$dep" || true
  [ -n "$NS" ] && break
done
[ -n "$NS" ] || tdie "none of these deployments were found in any namespace: ${WANTED_DEPLOYS[*]} -- wrong kubeconfig/context?"

for dep in "${WANTED_DEPLOYS[@]}"; do
  if kubectl -n "$NS" get "deployment/$dep" >/dev/null 2>&1; then
    ACTIVE_DEPLOYS+=("$dep")
  elif [ "$DEPLOYS_EXPLICIT" = yes ]; then
    tdie "deployment '$dep' not found in namespace $NS (explicitly requested via -d)"
  else
    techo "no $dep in $NS -- skipping"
  fi
done
[ "${#ACTIVE_DEPLOYS[@]}" -gt 0 ] || tdie "no requested deployment exists in namespace $NS"
techo "collecting from: ${ACTIVE_DEPLOYS[*]}"

for dep in "${ACTIVE_DEPLOYS[@]}"; do
  enable-profiling "$dep"
done

if [ "$PREPARE_ONLY" = yes ]; then
  techo "PREPARE ONLY (-P): PROFILING is enabled and the pod(s) have rolled."
  techo "Let the workload run so the symptom re-establishes, then collect with:"
  techo "  collect-pprof.sh -n $NS"
  techo "That run will NOT restart anything, so its numbers are a real baseline."
  exit 0
fi

if [ -n "$POD" ]; then
  [ "${#ACTIVE_DEPLOYS[@]}" -eq 1 ] \
    || tdie "-p/POD overrides a single pod, but ${#ACTIVE_DEPLOYS[@]} deployments are active (${ACTIVE_DEPLOYS[*]}). Narrow with -d."
  kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1 \
    || tdie "pod '$POD' (-p) not found in namespace $NS"
fi

for dep in "${ACTIVE_DEPLOYS[@]}"; do
  # detect-pod runs in a command substitution, so it must never tdie: that exits
  # only the subshell and the caller's message then overwrites the accurate one.
  # It returns 2 for "profiling never appeared" and 1 for "no pod at all", and
  # the single error is produced here, in the shell that can actually exit.
  pod=$(detect-pod "$dep"); rc=$?
  case "$rc" in
    0) ;;
    2) tdie "[$dep] timed out after 120s waiting for a Ready pod carrying PROFILING=enable. The rollout may be stuck -- check: kubectl -n $NS rollout status deployment/$dep" ;;
    *) tdie "[$dep] no Running, non-terminating pod in $NS" ;;
  esac
  dep_set "$dep" pod "$pod"
  techo "[$dep] pod: $pod"
done

select-schedule
[ "$SETTLE_SECONDS" -gt 0 ] && settle
setup
start-port-forwards

# ==== Sampling loop ====
# One offset schedule shared by ALL targets, so palette and ally are captured at
# the SAME instants -- that is what makes a cross-component comparison valid.
IFS=',' read -r -a OFFSETS <<<"$SAMPLE_SCHEDULE"
: > "$TMPDIR/SAMPLES.txt"
{
  printf 'sample sets in this bundle\n'
  printf '==========================\n'
  printf 'deployments          : %s\n' "${ACTIVE_DEPLOYS[*]}"
  printf 'we restarted the pod : %s\n' "$WE_RESTARTED"
  printf 'schedule             : %s\n' "$SAMPLE_SCHEDULE"
  printf 'schedule chosen bc   : %s\n' "$SCHEDULE_REASON"
  if [ "$WE_RESTARTED" = yes ]; then
    printf 'offset ~= time since process start; sample-0 IS a cold start.\n\n'
  else
    printf 'NO restart occurred, so offset is time since THIS RUN began, not since\n'
    printf 'process start. sample-0 is "as found", not a cold start. Read the\n'
    printf 'container_age column -- that is the authoritative number.\n\n'
  fi
  printf '%-12s %-10s %-14s %-14s %s\n' SUBDIR OFFSET_S TARGET CONTAINER_AGE_S COLLECTED_AT_UTC
} >>"$TMPDIR/SAMPLES.txt"

RUN_START=$SECONDS
for idx in "${!OFFSETS[@]}"; do
  off="${OFFSETS[$idx]}"
  [[ "$off" =~ ^[0-9]+$ ]] || tdie "SAMPLE_SCHEDULE entries must be integers: '$off'"
  target=$((RUN_START + off))
  now=$SECONDS
  if [ "$now" -lt "$target" ]; then
    wait_s=$((target - now))
    techo "waiting ${wait_s}s until sample offset ${off}s ($((idx+1))/${#OFFSETS[@]})"
    remaining=$wait_s
    while [ "$remaining" -gt 0 ]; do
      step=$(( remaining > 30 ? 30 : remaining ))
      sleep "$step"; remaining=$((remaining - step))
      printf '    %ds remaining\r' "$remaining" >&2
      # A dead port-forward mid-wait would silently void every later sample.
      for pid in "${PF_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null || tdie "a port-forward died during the wait -- is the pod still Running?"
      done
    done
    printf '\n' >&2
  fi

  SUB="sample-${off}"
  techo "=== sample $((idx+1))/${#OFFSETS[@]}: offset=${off}s -> $SUB/"
  for i in "${!TARGET_PORTS[@]}"; do
    age=$(container-age "$i")
    printf '%-12s %-10s %-14s %-14s %s\n' "$SUB" "$off" "${TARGET_LABELS[$i]}" \
      "${age:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$TMPDIR/SAMPLES.txt"
  done

  collect-metrics "$SUB"
  collect-profiles "$SUB"
  : > "$TMPDIR/$SUB/pod-top.txt"
  for dep in "${ACTIVE_DEPLOYS[@]}"; do
    n=1
    while [ "$n" -le "$TOP_SAMPLES" ]; do
      { printf '### %s  %s/%s  %s\n' "$dep" "$n" "$TOP_SAMPLES" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        kubectl -n "$NS" top pod "$(dep_get "$dep" pod)" --containers 2>&1; printf '\n'
      } >>"$TMPDIR/$SUB/pod-top.txt"
      [ "$n" -lt "$TOP_SAMPLES" ] && sleep "$TOP_GAP_SECONDS"
      n=$((n+1))
    done
  done
done
SUB=""

{
  printf '\nHow to read this:\n'
  printf '  CPU decaying across samples  -> warmup; do NOT cite sample-0 for magnitude.\n'
  printf '  CPU flat across samples      -> sustained; this is the real baseline.\n'
  printf '  workqueue_adds_total absent in sample-0 but present later is EXPECTED:\n'
  printf '    labeled Prometheus series do not exist until first increment.\n'
} >>"$TMPDIR/SAMPLES.txt"

collect-context
write-readme
archive
