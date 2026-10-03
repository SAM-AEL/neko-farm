#!/usr/bin/env bash
#
# Deploy the Neko stack to the VPS described in deploy.env.
#
# Design notes:
#   - profile/ and .env are NEVER synced. profile/ holds the logged-in browser session and
#     .env holds secrets; both are remote state, not build artifacts. They are
#     excluded from rsync, which also protects them from --delete.
#   - .env is pushed exactly once, on the first deploy when the remote has none.
#     After that the server's copy wins, so password rotation stays deliberate.
#   - cloudflared is not deployed here. It already runs on the VPS and forwards
#     to 127.0.0.1:7000, so all this script does is make Neko reachable there.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC1091
source deploy.env

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_DIM=$'\033[2m';  C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST"; }

# The link to the VPS is slow to open (measured 5-30s per handshake) and
# occasionally stalls past ConnectTimeout, which made a deploy fail at a random
# step. One multiplexed master connection is established once and then reused by
# every ssh call and by rsync; ControlPersist keeps it warm for the whole run and
# the EXIT trap removes it afterwards.
SSH_CTL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/neko-deploy.XXXXXX")
cleanup() {
  local rc=$?
  rm -rf "$SSH_CTL_DIR"
  return $rc
}
trap cleanup EXIT

SSH_OPTS=(
  -p "$DEPLOY_PORT"
  -o BatchMode=yes               # never prompt: a hang is worse than a failure
  -o ConnectTimeout=30           # measured 5-30s handshakes; 10s was too tight
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=6       # tolerate ~3min of dead link before giving up
  -o ControlMaster=auto
  -o ControlPath="$SSH_CTL_DIR/neko-%C"
  -o ControlPersist=300
)
# rsync does not inherit SSH_OPTS, so the same options are spelled out for -e.
# %C is the hashed connection tuple, so concurrent deploys cannot collide.
SSH_RSYNC="ssh -p $DEPLOY_PORT -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ControlMaster=auto -o ControlPath=$SSH_CTL_DIR/neko-%C -o ControlPersist=300"

RSYNC_EXCLUDES=(
  --exclude '.git/' --exclude 'node_modules/' --exclude '.commandcode/'
  --exclude '.yarn/' --exclude '.pnp.cjs'
  --exclude 'profile/' --exclude '.env' --exclude 'deploy.env'
  # Local secrets that must never reach the VPS.
  --exclude 'askpass.sh' --exclude '*.pem' --exclude '*.key'
)

# `docker` may or may not need sudo, depending on group membership.
DOCKER_SUDO=""
# Whether `sudo -n` works at all for this user. Tracked separately from
# DOCKER_SUDO: reaching the daemon unprivileged says nothing about root-only
# steps, which is what previously made the volume chown silently unrunnable.
SUDO_OK=false

# Every command issued here is idempotent (mkdir, test, df, chown, compose up),
# so retrying a lost connection cannot double-apply anything.
REMOTE_ATTEMPTS="${REMOTE_ATTEMPTS:-3}"

remote() {
  local attempt=1 rc=0
  while :; do
    rc=0
    ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" "$@" || rc=$?
    if (( rc == 0 )); then return 0; fi
    if (( attempt >= REMOTE_ATTEMPTS )); then return "$rc"; fi
    warn "ssh $DEPLOY_HOST:$DEPLOY_PORT failed (exit $rc) — retry $attempt/$REMOTE_ATTEMPTS"
    sleep $(( attempt * 3 ))
    attempt=$(( attempt + 1 ))
  done
}

# No retry: stdin is consumed by the first attempt, so a retry would write an
# empty file. Used only to stream .env.
remote_once() { ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" "$@"; }

# DOCKER_SUDO is decided by remote_preflight, which probes the daemon. A
# configurable sudo mode is deliberately not offered: a password-prompting
# sudo over a non-interactive ssh hangs the deploy instead of failing.
# `docker compose` therefore escalates only when the daemon demands it.
remote_docker() { if [[ -n "$DOCKER_SUDO" ]]; then remote "$DOCKER_SUDO" "$@"; else remote "$@"; fi; }
# Root-only work (chown under /var/lib/docker) needs real root even when docker
# itself runs unprivileged, so it uses SUDO_OK rather than DOCKER_SUDO.
remote_root() { if [[ "$SUDO_OK" == true ]]; then remote "sudo -n" "$@"; else remote "$@"; fi; }

# ---------------------------------------------------------------- preflight --

preflight() {
  log "Checking configuration"
  for var in DEPLOY_HOST DEPLOY_USER DEPLOY_PORT DEPLOY_PATH; do
    [[ -n "${!var:-}" ]] || die "$var is not set in deploy.env"
  done
  [[ -n "$DEPLOY_HOST" ]] || die "DEPLOY_HOST is empty — edit deploy.env"

  for f in docker-compose.yml neko.yaml policies.json .env; do
    [[ -f "$f" ]] || die "$f is missing"
  done

  docker compose config --quiet || die "docker-compose.yml does not validate"
  dim "compose config valid"

  remote true \
    || die "cannot reach $DEPLOY_USER@$DEPLOY_HOST port $DEPLOY_PORT — check DEPLOY_HOST/DEPLOY_USER/DEPLOY_PORT and your SSH key"

  resolve_path
}

# rsync runs as the SSH user, so the deploy directory must be writable by that
# user — a root-owned path like /opt/neko-farm cannot work. Resolve ~ against
# the *remote* home rather than expanding it locally.
resolve_path() {
  case "$DEPLOY_PATH" in
    "~"|"") DEPLOY_PATH=$(remote "echo \$HOME") ;;
    # One round trip, not two: each remote call costs a handshake on this link.
    "~/"*)  DEPLOY_PATH="$(remote "echo \$HOME/${DEPLOY_PATH#\~/}")" ;;
  esac
}

# ------------------------------------------------------------------ remote --

remote_preflight() {
  log "Checking VPS"
  # Probe the daemon, not the client: `docker --version` succeeds even for a
  # user with no daemon access, which made the old check pass pointlessly.
  if remote "docker info" >/dev/null 2>&1; then
    DOCKER_SUDO=""
    dim "docker daemon accessible directly (no sudo needed)"
  elif remote "sudo -n docker info" >/dev/null 2>&1; then
    DOCKER_SUDO="sudo -n"
    dim "docker daemon needs passwordless sudo"
  else
    die "no docker access as $DEPLOY_USER, and passwordless sudo is unavailable.
       Fix it on the VPS — either:
         sudo usermod -aG docker $DEPLOY_USER
       then reconnect so the new group takes effect. Note that membership of the
       docker group is equivalent to root access on that host."
  fi

  # Root escalation is tracked on its own. The volume chown below is the only
  # step that genuinely needs root, and it is needed even when docker itself is
  # reachable as $DEPLOY_USER. Deriving it from DOCKER_SUDO meant the chown ran
  # unprivileged, failed with "Permission denied", and printed a warning telling
  # the operator to run sudo by hand even though passwordless sudo already
  # worked — the deploy "succeeded" but Neko lost its session on every restart.
  if remote "sudo -n true" >/dev/null 2>&1; then
    SUDO_OK=true
    dim "passwordless sudo available for root-only steps"
  else
    SUDO_OK=false
    dim "no passwordless sudo — Neko sessions will not persist across restarts"
  fi

  # awk rather than `tail -1` so a header line cannot be mistaken for the value,
  # and the result is validated rather than coerced — silently concatenating
  # digits from a whole df line would fake a healthy disk.
  local free_mb
  free_mb=$(remote "df -Pm / 2>/dev/null | awk 'NR==2 {print \$4}'" | head -1)
  [[ "$free_mb" =~ ^[0-9]+$ ]] || die "could not read free space on the VPS (got: '$free_mb')"
  [[ "$free_mb" -ge 1500 ]] || warn "only ${free_mb} MB free on / — the image needs ~1.5 GB"
  dim "docker present, ${free_mb} MB free"

  # Fail here, with an actionable message, rather than partway through rsync.
  remote "mkdir -p '$DEPLOY_PATH'" 2>/dev/null \
    || die "cannot create $DEPLOY_PATH as $DEPLOY_USER — set DEPLOY_PATH to somewhere writable, e.g. ~/neko-farm"
  remote "test -w '$DEPLOY_PATH'" 2>/dev/null \
    || die "$DEPLOY_PATH is not writable by $DEPLOY_USER — rsync runs unprivileged, so it must be owned by that user"
  dim "deploy path $DEPLOY_PATH"
}

# Push .env only when the server has none, so secrets are not overwritten on
# every run but a first deploy still works unattended.
seed_env() {
  if remote "test -f '$DEPLOY_PATH/.env'"; then
    log "Keeping existing remote .env"
    return
  fi
  log "Seeding remote .env from local (first deploy only)"
  local tmp ip
  tmp=$(mktemp)
  # VPS_PUBLIC_IP defaults to DEPLOY_HOST so Neko advertises the right address.
  ip=$(grep -E '^VPS_PUBLIC_IP=' .env | cut -d= -f2- | tr -d '[:space:]')
  [[ -n "$ip" ]] || ip="$DEPLOY_HOST"
  sed "s|^VPS_PUBLIC_IP=.*|VPS_PUBLIC_IP=$ip|" .env >"$tmp"
  # Redirect the file, not its path: the remote shell does the write and the
  # mv, so the .env appears atomically rather than half-written.
  # remote_once, not remote: stdin is a one-shot stream, so a retry would write a
  # truncated or empty .env. The master connection already covers the slow path.
  if ! remote_once "cat > '$DEPLOY_PATH/.env.tmp' && mv '$DEPLOY_PATH/.env.tmp' '$DEPLOY_PATH/.env'" <"$tmp"; then
    rm -f "$tmp"
    die "failed to write $DEPLOY_PATH/.env on the VPS"
  fi
  rm -f "$tmp"
  remote "chmod 600 '$DEPLOY_PATH/.env'"
  dim "VPS_PUBLIC_IP=$ip"
}

sync_files() {
  log "Syncing files to $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH"
  remote "mkdir -p '$DEPLOY_PATH'"
  local args=(-az --delete "${RSYNC_EXCLUDES[@]}" -e "$SSH_RSYNC" --timeout=600)
  [[ "${DEPLOY_PRUNE:-1}" == "1" ]] || args=(-az "${RSYNC_EXCLUDES[@]}" -e "$SSH_RSYNC" --timeout=600)
  rsync "${args[@]}" ./ "$DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH/"
}

start() {
  log "Starting stack"
  remote "mkdir -p '$DEPLOY_PATH/profile'"
  # Chown first: a file left root-owned by an earlier mount would otherwise
  # block the copy below, since the SSH user cannot overwrite it.
  # Firefox refuses to run against a root-owned profile.
  remote_root "chown -R 1000:1000 '$DEPLOY_PATH/profile'"
  # The named volume is created root-owned by docker, but Neko runs as UID 1000
  # and cannot write its session file without this. Uses remote_root, not
  # remote_docker: the volume lives under /var/lib/docker and is unreadable to
  # the SSH user even when docker itself needs no sudo.
  local vol
  vol=$(remote_docker "docker volume ls -q --filter name=neko-farm_neko-data 2>/dev/null | head -1")
  if [[ -n "$vol" ]]; then
    if remote_root "chown -R 1000:1000 /var/lib/docker/volumes/$vol/_data" 2>/dev/null; then
      dim "volume $vol owned by 1000:1000"
    else
      warn "could not chown $vol (needs root). Neko sessions will not persist across"
      warn "restarts, so you will re-log in to Neko each time. Fix once with:"
      printf '%s\n' "      ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST \\" \
        "        'sudo chown -R 1000:1000 /var/lib/docker/volumes/$vol/_data'"
    fi
  fi
  # user.js is copied into the profile rather than bind-mounted into it: nesting
  # a mount inside the profile mount leaves a read-only mountpoint that
  # `chown -R` cannot traverse, which aborts the deploy.
  if [[ -f user.js ]]; then
    # Unlink first rather than overwrite: a file left root-owned by an earlier
    # nested mount cannot be overwritten by the SSH user, but it can be removed,
    # since that only needs write permission on the directory.
    remote "rm -f '$DEPLOY_PATH/profile/user.js' && cp '$DEPLOY_PATH/user.js' '$DEPLOY_PATH/profile/user.js'"
    dim "user.js installed into profile"
  fi
  remote_docker "cd '$DEPLOY_PATH' && docker compose up -d --remove-orphans"
}

report() {
  log "Status"
  remote_docker "cd '$DEPLOY_PATH' && docker compose ps" || true
  echo
  warn "Check the logs for 'neko ready':"
  dim "ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST 'docker logs --tail 30 neko-farm-neko-1'"
  echo
  if [[ -n "${PUBLIC_HOSTNAME:-}" ]]; then
    log "Open https://$PUBLIC_HOSTNAME and log in with NEKO_PASSWORD from .env"
    dim "First time only: log in, sign in once, pick a low quality, and close the tab."
  fi
  # TCPMUX is configured (NEKO_WEBRTC_TCPMUX=52000), so media is a single TCP
  # port, not the 52000-52100/udp range. Telling the operator to open UDP sent
  # them chasing a firewall rule that the stack does not use.
  warn "Media is WebRTC over TCP ${DEPLOY_HOST}:52000 (TCPMUX) and does NOT go through the tunnel."
  dim "UI loads but picture is black = TCP 52000 is blocked upstream, or VPS_PUBLIC_IP is wrong."
}

main() {
  preflight
  remote_preflight
  sync_files
  seed_env
  start
  report
}

if [[ "${1:-}" == "--check" ]]; then
  preflight
  remote_preflight
  log "Preflight passed"
  exit 0
fi

main "$@"
