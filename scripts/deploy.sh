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

SSH_OPTS=(-p "$DEPLOY_PORT" -o ConnectTimeout=10 -o ServerAliveInterval=30)
RSYNC_EXCLUDES=(
  --exclude '.git/' --exclude 'node_modules/' --exclude '.commandcode/'
  --exclude '.yarn/' --exclude '.pnp.cjs'
  --exclude 'profile/' --exclude '.env' --exclude 'deploy.env'
)

remote() { ssh "${SSH_OPTS[@]}" "$DEPLOY_USER@$DEPLOY_HOST" "$@"; }
remote_sudo() { if [[ -n "${DEPLOY_SUDO:-}" ]]; then remote "$DEPLOY_SUDO" "$@"; else remote "$@"; fi; }

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

  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$DEPLOY_USER@$DEPLOY_HOST" true 2>/dev/null \
    || die "cannot reach $DEPLOY_USER@$DEPLOY_HOST port $DEPLOY_PORT — check DEPLOY_HOST/DEPLOY_USER/DEPLOY_PORT and your SSH key"

  resolve_path
}

# rsync runs as the SSH user, so the deploy directory must be writable by that
# user — a root-owned path like /opt/neko-farm cannot work. Resolve ~ against
# the *remote* home rather than expanding it locally.
resolve_path() {
  case "$DEPLOY_PATH" in
    "~"|"") DEPLOY_PATH=$(remote "echo \$HOME") ;;
    "~/"*)  DEPLOY_PATH="$(remote "echo \$HOME")/${DEPLOY_PATH#\~/}" ;;
  esac
}

# ------------------------------------------------------------------ remote --

remote_preflight() {
  log "Checking VPS"
  remote "docker --version" >/dev/null 2>&1 || die "docker is not installed on the VPS"
  remote "docker compose version" >/dev/null 2>&1 || die "docker compose plugin is not installed on the VPS"

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
  if ! remote "cat > '$DEPLOY_PATH/.env.tmp' && mv '$DEPLOY_PATH/.env.tmp' '$DEPLOY_PATH/.env'" <"$tmp"; then
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
  local args=(-az --delete "${RSYNC_EXCLUDES[@]}" -e "ssh -p $DEPLOY_PORT")
  [[ "${DEPLOY_PRUNE:-1}" == "1" ]] || args=(-az "${RSYNC_EXCLUDES[@]}" -e "ssh -p $DEPLOY_PORT")
  rsync "${args[@]}" ./ "$DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PATH/"
}

start() {
  log "Starting stack"
  remote "mkdir -p '$DEPLOY_PATH/profile'"
  # Firefox refuses to run against a root-owned profile.
  remote_sudo "chown -R 1000:1000 '$DEPLOY_PATH/profile'"
  remote_sudo "cd '$DEPLOY_PATH' && docker compose up -d --remove-orphans"
}

report() {
  log "Status"
  remote "docker compose -f '$DEPLOY_PATH/docker-compose.yml' ps" || true
  echo
  warn "Check the logs for 'neko ready':"
  dim "ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST 'docker logs --tail 30 neko-farm-neko-1'"
  echo
  if [[ -n "${PUBLIC_HOSTNAME:-}" ]]; then
    log "Open https://$PUBLIC_HOSTNAME and log in with NEKO_PASSWORD from .env"
    dim "First time only: log in, sign in once, pick a low quality, and close the tab."
  fi
  warn "Media is WebRTC over UDP ${DEPLOY_HOST}:52000-52100 and does NOT go through the tunnel."
  dim "UI loads but picture is black = that UDP range is blocked."
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
