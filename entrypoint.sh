#!/usr/bin/env bash
#
# Register this container as a GitHub Actions self-hosted runner and keep it
# serving jobs. Everything is derived at boot from one operator-supplied token,
# so a Railway template needs no pre-computed registration credential.
#
set -uo pipefail

log() { printf '%s runner: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- configuration
[ -n "${GITHUB_PAT:-}" ] || die "GITHUB_PAT is not set. Create a token with 'repo' scope (repository runner) or 'admin:org' scope (organization runner) and set it on this service."
[ -n "${GITHUB_SCOPE:-}" ] || die "GITHUB_SCOPE is not set. Use 'owner/repository' for a repository runner or 'owner' for an organization runner."

GITHUB_API="${GITHUB_API:-https://api.github.com}"
RUNNER_GROUP_ID="${RUNNER_GROUP_ID:-1}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,railway}"
RUNNER_WORK="${RUNNER_WORK:-/home/runner/_work}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
HEALTH_ROOT="${HEALTH_ROOT:-/home/runner/.health}"
PORT="${PORT:-8080}"

# Accept a pasted browser URL as well as the bare form.
SCOPE="$GITHUB_SCOPE"
SCOPE="${SCOPE#https://github.com/}"
SCOPE="${SCOPE#http://github.com/}"
SCOPE="${SCOPE#github.com/}"
SCOPE="${SCOPE%.git}"
SCOPE="${SCOPE%/}"

case "$SCOPE" in
  */*/*) die "GITHUB_SCOPE must be 'owner/repository' or 'owner', got '${GITHUB_SCOPE}'." ;;
  */*)   SCOPE_PATH="repos/${SCOPE}"; SCOPE_KIND="repository" ;;
  "")    die "GITHUB_SCOPE is empty after parsing '${GITHUB_SCOPE}'." ;;
  *)     SCOPE_PATH="orgs/${SCOPE}";  SCOPE_KIND="organization" ;;
esac

# One runner name per replica AND per deployment: the replica id can repeat across
# deployments, and a new container deletes any registration holding its name, which
# would kill the job a draining container of the previous deployment is still running.
short_id() { printf '%s' "$1" | tr -cd 'a-zA-Z0-9' | cut -c1-8; }
SUFFIX="$(short_id "${RAILWAY_REPLICA_ID:-$(hostname)}")"
[ -n "$SUFFIX" ] || SUFFIX="0"
[ -n "${RAILWAY_DEPLOYMENT_ID:-}" ] && SUFFIX="$(short_id "$RAILWAY_DEPLOYMENT_ID")-${SUFFIX}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-railway}-${SUFFIX}}"

mkdir -p "$RUNNER_WORK" "$HEALTH_ROOT"
rm -f "$HEALTH_ROOT/healthz"

log "scope=${SCOPE} (${SCOPE_KIND}) name=${RUNNER_NAME} labels=${RUNNER_LABELS} ephemeral=${RUNNER_EPHEMERAL}"

# --------------------------------------------------------------- GitHub helpers
gh_api() {
  # gh_api <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  local -a args=(
    -sS --fail-with-body --max-time 30
    -X "$method" "${GITHUB_API}/${path}"
    -H "Authorization: Bearer ${GITHUB_PAT}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$body")
  fi
  curl "${args[@]}"
}

labels_json() {
  printf '%s' "$RUNNER_LABELS" \
    | jq -Rc 'split(",") | map(sub("^\\s+";"") | sub("\\s+$";"")) | map(select(length > 0))'
}

# A runner name must be unique. A container killed mid-job leaves its registration
# behind, so clear our own name before claiming it again. Only ever deletes the
# name this replica owns.
release_runner_name() {
  local id
  id=$(gh_api GET "${SCOPE_PATH}/actions/runners?per_page=100" 2>/dev/null \
        | jq -r --arg n "$RUNNER_NAME" '.runners[]? | select(.name == $n) | .id' | head -n1)
  if [ -n "${id:-}" ]; then
    log "removing stale registration for ${RUNNER_NAME} (id ${id})"
    gh_api DELETE "${SCOPE_PATH}/actions/runners/${id}" >/dev/null 2>&1 || true
  fi
}

runner_is_online() {
  gh_api GET "${SCOPE_PATH}/actions/runners?per_page=100" 2>/dev/null \
    | jq -e --arg n "$RUNNER_NAME" \
        'any(.runners[]?; .name == $n and .status == "online")' >/dev/null 2>&1
}

# ---------------------------------------------------------------- health surface
# Railway probes /healthz. The file exists only while GitHub itself reports this
# runner online, so a bad token or a wedged listener fails the deploy instead of
# reporting SUCCESS over a runner that never picked up a job.
busybox httpd -f -p "${PORT}" -h "${HEALTH_ROOT}" &
HTTPD_PID=$!
log "health endpoint listening on :${PORT}/healthz"

health_loop() {
  local misses=0
  while true; do
    if runner_is_online; then
      misses=0
      printf 'ok\n' > "${HEALTH_ROOT}/healthz"
    else
      misses=$((misses + 1))
      # Tolerate the short gap between one ephemeral job ending and the next
      # registration; only a sustained outage should fail the probe.
      [ "$misses" -ge 3 ] && rm -f "${HEALTH_ROOT}/healthz"
    fi
    sleep 20
  done
}
health_loop &
HEALTH_PID=$!

# ---------------------------------------------------------------------- shutdown
SHUTTING_DOWN=0
RUNNER_PID=""

# The listener cancels its running job on SIGTERM, so hold the signal back until the
# job's Runner.Worker exits; Railway's draining window bounds the wait.
on_term() {
  [ "$SHUTTING_DOWN" -eq 1 ] && return 0
  SHUTTING_DOWN=1
  [ -n "$RUNNER_PID" ] || return 0
  if pgrep -f Runner.Worker >/dev/null; then
    log "shutdown signal received; letting the runner finish its current job"
  else
    log "shutdown signal received; runner idle, stopping"
  fi
  (
    while pgrep -f Runner.Worker >/dev/null; do sleep 5; done
    kill -TERM "$RUNNER_PID" 2>/dev/null
  ) &
  return 0
}
trap on_term TERM INT

cleanup() {
  kill -TERM "$HEALTH_PID" "$HTTPD_PID" 2>/dev/null
  rm -f "${HEALTH_ROOT}/healthz"
  release_runner_name
}
trap cleanup EXIT

# Run the listener in the background and wait on it, so bash can service signals
# while a job is in flight — a foreground child would defer them until it exits.
await_runner() {
  "$@" &
  RUNNER_PID=$!
  local rc=0
  while :; do
    wait "$RUNNER_PID"; rc=$?
    # 128+n means `wait` was interrupted by our own trap, not that the child died.
    if [ "$rc" -gt 128 ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
      continue
    fi
    break
  done
  RUNNER_PID=""
  return "$rc"
}

# ------------------------------------------------------------------ persistent
# One long-lived registration that serves job after job. Lower per-job latency,
# but the workspace is reused, so only point it at code you trust.
run_persistent() {
  local token
  token=$(gh_api POST "${SCOPE_PATH}/actions/runners/registration-token" \
            | jq -r '.token // empty')
  [ -n "$token" ] || die "could not obtain a registration token for ${SCOPE}. Check that GITHUB_PAT is valid and has 'repo' (repository) or 'admin:org' (organization) scope."

  ./config.sh \
    --unattended --replace --disableupdate \
    --url "https://github.com/${SCOPE}" \
    --token "$token" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --runnergroup "${RUNNER_GROUP:-Default}" \
    --work "$RUNNER_WORK" \
    || die "runner configuration failed for ${SCOPE}"

  log "configured as a persistent runner; waiting for jobs"
  await_runner ./run.sh
}

# ------------------------------------------------------------------- ephemeral
# A fresh just-in-time registration per job. The listener exits once its job is
# done; we mint the next registration and go again without recycling the
# container, which keeps Railway's restart budget for real failures.
run_ephemeral() {
  local body resp jit
  while [ "$SHUTTING_DOWN" -eq 0 ]; do
    release_runner_name

    body=$(jq -nc \
      --arg name "$RUNNER_NAME" \
      --argjson gid "$RUNNER_GROUP_ID" \
      --argjson labels "$(labels_json)" \
      --arg work "$RUNNER_WORK" \
      '{name: $name, runner_group_id: $gid, labels: $labels, work_folder: $work}')

    resp=$(gh_api POST "${SCOPE_PATH}/actions/runners/generate-jitconfig" "$body")
    jit=$(printf '%s' "$resp" | jq -r '.encoded_jit_config // empty')

    if [ -z "$jit" ]; then
      log "could not generate a runner configuration: $(printf '%s' "$resp" | jq -c '{message, errors}' 2>/dev/null || printf '%s' "$resp")"
      log "check that GITHUB_PAT is valid and has 'repo' (repository) or 'admin:org' (organization) scope for ${SCOPE}"
      sleep 30
      continue
    fi

    log "registered with ${SCOPE}; waiting for a job"
    await_runner ./run.sh --jitconfig "$jit"
    [ "$SHUTTING_DOWN" -eq 0 ] && log "job finished; re-registering"

    # A just-in-time runner is single-use, so the workspace starts clean.
    rm -rf "${RUNNER_WORK:?}"/* 2>/dev/null
  done
}

case "$(printf '%s' "$RUNNER_EPHEMERAL" | tr '[:upper:]' '[:lower:]')" in
  false|0|no) run_persistent ;;
  *)          run_ephemeral ;;
esac

log "runner stopped"
