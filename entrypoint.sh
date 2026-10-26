#!/usr/bin/env bash
# Entrypoint for the self-hosted GitHub Actions runner container.
#
# Phase 1 (root): make the mounted docker socket usable by the `runner` user,
#                 fix ownership of the work directory, then re-exec as `runner`.
# Phase 2 (runner): exchange GITHUB_PAT for a registration token, register,
#                   run, and unregister on SIGTERM/SIGINT.
set -euo pipefail

RUNNER_HOME="${RUNNER_HOME:-/home/runner}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Phase 1: root setup, then drop privileges
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    if [ -S "$DOCKER_SOCK" ]; then
        sock_gid="$(stat -c '%g' "$DOCKER_SOCK")"
        if [ "$sock_gid" = "0" ]; then
            # Socket owned by root group (e.g. Docker Desktop): let runner use it directly.
            chmod g+rw "$DOCKER_SOCK" 2>/dev/null || true
            usermod -aG root runner
        else
            if ! getent group "$sock_gid" >/dev/null; then
                groupadd -g "$sock_gid" docker-host
            fi
            usermod -aG "$sock_gid" runner
        fi
        log "docker socket $DOCKER_SOCK (gid $sock_gid) granted to runner"
    else
        log "no docker socket at $DOCKER_SOCK; docker commands in jobs will not work"
    fi

    work_dir="$RUNNER_HOME/${RUNNER_WORKDIR:-_work}"
    mkdir -p "$work_dir"
    chown runner:runner "$RUNNER_HOME" "$work_dir"

    exec gosu runner "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Phase 2: running as `runner`
# ---------------------------------------------------------------------------
cd "$RUNNER_HOME"

[ -n "${GITHUB_URL:-}" ] || die "GITHUB_URL is required (e.g. https://github.com/my-org or https://github.com/my-org/my-repo)"
[ -n "${GITHUB_PAT:-}" ]  || die "GITHUB_PAT is required (org: admin:org scope; repo: repo scope)"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-false}"

# Parse GITHUB_URL -> host, owner, optional repo.
url="${GITHUB_URL%/}"
url="${url#http://}"; url="${url#https://}"
host="${url%%/*}"
path="${url#"$host"}"; path="${path#/}"
owner="${path%%/*}"
repo=""
[ "$path" != "$owner" ] && repo="${path#*/}"

[ -n "$host" ] && [ -n "$owner" ] || die "GITHUB_URL must look like https://github.com/<owner> or https://github.com/<owner>/<repo>"
case "$repo" in */*) die "GITHUB_URL must point at an organization or a single repository, got: $GITHUB_URL" ;; esac

if [ -z "${GITHUB_API_URL:-}" ]; then
    if [ "$host" = "github.com" ]; then
        GITHUB_API_URL="https://api.github.com"
    else
        GITHUB_API_URL="https://${host}/api/v3"   # GitHub Enterprise Server
    fi
fi

if [ -n "$repo" ]; then
    scope="repository ${owner}/${repo}"
    api_base="${GITHUB_API_URL}/repos/${owner}/${repo}/actions/runners"
else
    scope="organization ${owner}"
    api_base="${GITHUB_API_URL}/orgs/${owner}/actions/runners"
fi

# fetch_token <registration-token|remove-token>
fetch_token() {
    local kind="$1" response token
    response="$(curl -sS -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${api_base}/${kind}")" || die "request for ${kind} failed"
    token="$(printf '%s' "$response" | jq -r '.token // empty')"
    if [ -z "$token" ]; then
        log "GitHub API response: $(printf '%s' "$response" | jq -c '.' 2>/dev/null || printf '%s' "$response")"
        die "could not obtain ${kind} for ${scope} (check GITHUB_PAT scopes and GITHUB_URL)"
    fi
    printf '%s' "$token"
}

unregister() {
    if [ -f .runner ]; then
        log "removing runner '${RUNNER_NAME}' from ${scope}"
        local token
        if token="$(fetch_token remove-token)"; then
            ./config.sh remove --token "$token" || log "config.sh remove failed (runner may already be gone)"
        fi
    fi
}

# A leftover registration (e.g. persisted volume) is removed and re-created so
# that labels/name from the current environment always win.
if [ -f .runner ]; then
    log "existing registration found; re-registering"
    unregister
fi

log "registering runner '${RUNNER_NAME}' with ${scope}"
[ -n "$RUNNER_LABELS" ] && log "labels: ${RUNNER_LABELS}"
[ -n "$RUNNER_GROUP" ]  && log "runner group: ${RUNNER_GROUP}"
[ "$RUNNER_EPHEMERAL" = "true" ] && log "ephemeral mode: container exits after one job"

config_args=(
    --unattended
    --url "$GITHUB_URL"
    --token "$(fetch_token registration-token)"
    --name "$RUNNER_NAME"
    --work "$RUNNER_WORKDIR"
    --replace
    --disableupdate
)
[ -n "$RUNNER_LABELS" ] && config_args+=(--labels "$RUNNER_LABELS")
[ -n "$RUNNER_GROUP" ]  && config_args+=(--runnergroup "$RUNNER_GROUP")
[ "$RUNNER_EPHEMERAL" = "true" ] && config_args+=(--ephemeral)

./config.sh "${config_args[@]}"

# Forward signals to the runner, then unregister.
runner_pid=""
on_signal() {
    local sig="$1"
    log "received SIG${sig}, stopping runner"
    if [ -n "$runner_pid" ]; then
        kill -s "$sig" "$runner_pid" 2>/dev/null || true
        wait "$runner_pid" 2>/dev/null || true
    fi
    unregister
    exit 0
}
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT

log "starting runner"
./run.sh "$@" &
runner_pid=$!
wait "$runner_pid"
exit_code=$?

# Ephemeral runners deregister themselves after the job; otherwise clean up.
unregister
exit "$exit_code"
