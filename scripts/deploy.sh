#!/usr/bin/env bash
#
# Deploy the Neko stack to the VPS (supports original x86_64 and Ampere A1 ARM64).
#
# Design notes:
#   - profile/ and .env are NEVER synced. profile/ holds the logged-in browser session and
#     .env holds secrets; both are remote state, not build artifacts. They are
#     excluded from rsync, which also protects them from --delete.
#   - .env is pushed exactly once, on the first deploy when the remote has none.
#     After that the server's copy wins, so password rotation stays deliberate.
#   - cloudflared is not deployed here. It already runs on the VPS and forwards
#     to 127.0.0.1:7000, so all this script does is make Neko reachable there.
#   - Multi-arch: ghcr.io/m1k1o/neko/firefox:3 natively provides both linux/amd64
#     and linux/arm64 manifests. The target architecture is probed at runtime.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

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

# ------------------------------------------------------------------ arguments & targets --

CHECK_ONLY=false
TARGET_NAME="${DEPLOY_TARGET:-}"

# Preserve any variables explicitly exported in the current shell environment
USER_SET_HOST="${DEPLOY_HOST:-}"
USER_SET_USER="${DEPLOY_USER:-}"
USER_SET_PORT="${DEPLOY_PORT:-}"
USER_SET_PATH="${DEPLOY_PATH:-}"
USER_SET_SSH_KEY="${SSH_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --target)
      TARGET_NAME="$2"
      shift 2
      ;;
    --target=*)
      TARGET_NAME="${1#*=}"
      shift
      ;;
    --oracle|oracle)
      TARGET_NAME="oracle"
      shift
      ;;
    --original|original)
      TARGET_NAME="original"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--target original|oracle|<custom>] [--check]"
      echo ""
      echo "Targets:"
      echo "  original   Deploy to original x86_64 VPS (reads deploy.original.env)"
      echo "  oracle     Deploy to Oracle Ampere A1 ARM64 VPS (reads deploy.oracle.env / Doppler)"
      echo ""
      echo "Options:"
      echo "  --check    Run preflight and connectivity tests without deploying"
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_NAME" && ! "$1" =~ ^- ]]; then
        TARGET_NAME="$1"
        shift
      else
        warn "Unknown argument: $1"
        shift
      fi
      ;;
  esac
done

# Source target environment file
if [[ -n "$TARGET_NAME" && -f "deploy.${TARGET_NAME}.env" ]]; then
  # shellcheck disable=SC1090
  source "deploy.${TARGET_NAME}.env"
elif [[ -f "deploy.env" ]]; then
  # shellcheck disable=SC1091
  source "deploy.env"
fi

# Doppler integration fallback (shared with Kwitch & Denvo)
# If target is oracle or DEPLOY_HOST is missing, attempt to fill from buzzeee/prd_infra
if [[ -z "${DEPLOY_HOST:-}" || "$TARGET_NAME" == "oracle" ]]; then
  if [[ -f "$HOME/.config/denvo/tokens.sh" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.config/denvo/tokens.sh"
  fi
  DOPPLER_INFRA_TOKEN="${DOPPLER_BUZZEEE_INFRA:-${DOPPLER_TOKEN_INFRA:-}}"
  if [[ -n "$DOPPLER_INFRA_TOKEN" ]] && command -v doppler >/dev/null 2>&1; then
    INFRA_JSON="$(DOPPLER_TOKEN="$DOPPLER_INFRA_TOKEN" doppler secrets download --no-file --format json --project buzzeee --config prd_infra 2>/dev/null || true)"
    if [[ -n "$INFRA_JSON" ]]; then
      DOPPLER_HOST="$(printf '%s' "$INFRA_JSON" | grep -o '"KWITCH_VPS_HOST":"[^"]*"' | cut -d'"' -f4 || true)"
      DOPPLER_PORT="$(printf '%s' "$INFRA_JSON" | grep -o '"KWITCH_VPS_PORT":"[^"]*"' | cut -d'"' -f4 || true)"
      DOPPLER_USER="$(printf '%s' "$INFRA_JSON" | grep -o '"KWITCH_VPS_USER":"[^"]*"' | cut -d'"' -f4 || true)"
      if [[ -z "${DEPLOY_HOST:-}" && -n "$DOPPLER_HOST" ]]; then
        DEPLOY_HOST="$DOPPLER_HOST"
        dim "DEPLOY_HOST loaded from Doppler buzzeee/prd_infra ($DEPLOY_HOST)"
      fi
      if [[ -z "${DEPLOY_PORT:-}" && -n "$DOPPLER_PORT" ]]; then
        DEPLOY_PORT="$DOPPLER_PORT"
      fi
      if [[ -z "${DEPLOY_USER:-}" && -n "$DOPPLER_USER" ]]; then
        DEPLOY_USER="$DOPPLER_USER"
      fi
    fi
  fi
fi

# Restore shell-exported overrides (they always take highest priority)
[[ -n "$USER_SET_HOST" ]] && DEPLOY_HOST="$USER_SET_HOST"
[[ -n "$USER_SET_USER" ]] && DEPLOY_USER="$USER_SET_USER"
[[ -n "$USER_SET_PORT" ]] && DEPLOY_PORT="$USER_SET_PORT"
[[ -n "$USER_SET_PATH" ]] && DEPLOY_PATH="$USER_SET_PATH"
[[ -n "$USER_SET_SSH_KEY" ]] && SSH_KEY="$USER_SET_SSH_KEY"

: "${DEPLOY_USER:=sam}"
: "${DEPLOY_PORT:=22}"
: "${DEPLOY_PATH:=~/neko-farm}"
: "${SSH_KEY:=$HOME/.ssh/id_ed25519}"
: "${TARGET_NAME:=default}"

# Multiplexed SSH connection
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

if [[ -f "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
  SSH_RSYNC="ssh -i $SSH_KEY -p $DEPLOY_PORT -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ControlMaster=auto -o ControlPath=$SSH_CTL_DIR/neko-%C -o ControlPersist=300"
else
  SSH_RSYNC="ssh -p $DEPLOY_PORT -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ControlMaster=auto -o ControlPath=$SSH_CTL_DIR/neko-%C -o ControlPersist=300"
fi

RSYNC_EXCLUDES=(
  --exclude '.git/' --exclude 'node_modules/' --exclude '.commandcode/'
  --exclude '.yarn/' --exclude '.pnp.cjs'
  --exclude 'profile/' --exclude '.env' --exclude 'deploy.env' --exclude 'deploy.*.env'
  # Local secrets that must never reach the VPS.
  --exclude 'askpass.sh' --exclude '*.pem' --exclude '*.key'
)

# `docker` may or may not need sudo, depending on group membership.
DOCKER_SUDO=""
# Whether `sudo -n` works at all for this user.
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

# Escalates only when the daemon demands it.
remote_docker() { if [[ -n "$DOCKER_SUDO" ]]; then remote "$DOCKER_SUDO" "$@"; else remote "$@"; fi; }
# Root-only work (chown under /var/lib/docker) needs real root even when docker runs unprivileged.
remote_root() { if [[ "$SUDO_OK" == true ]]; then remote "sudo -n" "$@"; else remote "$@"; fi; }

# ---------------------------------------------------------------- preflight --

preflight() {
  log "Checking configuration (target: $TARGET_NAME)"
  for var in DEPLOY_HOST DEPLOY_USER DEPLOY_PORT DEPLOY_PATH; do
    [[ -n "${!var:-}" ]] || die "$var is not set in deploy configuration"
  done
  [[ -n "$DEPLOY_HOST" ]] || die "DEPLOY_HOST is empty — check deploy.env or deploy.${TARGET_NAME}.env"

  for f in docker-compose.yml neko.yaml policies.json .env; do
    [[ -f "$f" ]] || die "$f is missing"
  done

  docker compose config --quiet || die "docker-compose.yml does not validate"
  dim "compose config valid"

  remote true \
    || die "cannot reach $DEPLOY_USER@$DEPLOY_HOST port $DEPLOY_PORT — check DEPLOY_HOST/DEPLOY_USER/DEPLOY_PORT and your SSH key ($SSH_KEY)"

  resolve_path
}

resolve_path() {
  case "$DEPLOY_PATH" in
    "~"|"") DEPLOY_PATH=$(remote "echo \$HOME") ;;
    "~/"*)  DEPLOY_PATH="$(remote "echo \$HOME/${DEPLOY_PATH#\~/}")" ;;
  esac
}

# ------------------------------------------------------------------ remote --

remote_preflight() {
  log "Checking VPS ($DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PORT)"

  # Probe remote architecture (Multi-arch verification: AMD64 vs ARM64)
  local remote_arch
  remote_arch=$(remote "uname -m 2>/dev/null" || true)
  case "$remote_arch" in
    aarch64|arm64)
      log "Detected CPU: $remote_arch (ARM64 - Ampere A1 / Apple Silicon)"
      dim "Multi-arch image ghcr.io/m1k1o/neko/firefox:3 supports linux/arm64 natively"
      ;;
    x86_64|amd64)
      log "Detected CPU: $remote_arch (AMD64 / x86_64)"
      dim "Multi-arch image ghcr.io/m1k1o/neko/firefox:3 supports linux/amd64 natively"
      ;;
    *)
      warn "Unrecognized remote architecture: '$remote_arch'"
      ;;
  esac

  # Probe docker daemon access
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
       then reconnect so the new group takes effect."
  fi

  if remote "sudo -n true" >/dev/null 2>&1; then
    SUDO_OK=true
    dim "passwordless sudo available for root-only steps"
  else
    SUDO_OK=false
    dim "no passwordless sudo — Neko sessions will not persist across restarts"
  fi

  local free_mb
  free_mb=$(remote "df -Pm / 2>/dev/null | awk 'NR==2 {print \$4}'" | head -1)
  [[ "$free_mb" =~ ^[0-9]+$ ]] || die "could not read free space on the VPS (got: '$free_mb')"
  [[ "$free_mb" -ge 1500 ]] || warn "only ${free_mb} MB free on / — the image needs ~1.5 GB"
  dim "docker present, ${free_mb} MB free"

  remote "mkdir -p '$DEPLOY_PATH'" 2>/dev/null \
    || die "cannot create $DEPLOY_PATH as $DEPLOY_USER — set DEPLOY_PATH to somewhere writable, e.g. ~/neko-farm"
  remote "test -w '$DEPLOY_PATH'" 2>/dev/null \
    || die "$DEPLOY_PATH is not writable by $DEPLOY_USER — rsync runs unprivileged, so it must be owned by that user"
  dim "deploy path $DEPLOY_PATH"
}

seed_env() {
  if remote "test -f '$DEPLOY_PATH/.env'"; then
    log "Keeping existing remote .env"
    return
  fi
  log "Seeding remote .env from local (first deploy on $TARGET_NAME)"
  local tmp ip
  tmp=$(mktemp)
  # VPS_PUBLIC_IP MUST match DEPLOY_HOST so ICE candidates resolve directly to this host
  ip="${VPS_PUBLIC_IP:-$DEPLOY_HOST}"
  sed "s|^VPS_PUBLIC_IP=.*|VPS_PUBLIC_IP=$ip|" .env >"$tmp"

  # Append optional resource tuning if set
  if [[ -n "${NEKO_MEM_LIMIT:-}" ]]; then
    if grep -q '^NEKO_MEM_LIMIT=' "$tmp"; then
      sed -i "s|^NEKO_MEM_LIMIT=.*|NEKO_MEM_LIMIT=$NEKO_MEM_LIMIT|" "$tmp"
    else
      echo "NEKO_MEM_LIMIT=$NEKO_MEM_LIMIT" >> "$tmp"
    fi
  fi
  if [[ -n "${NEKO_SHM_SIZE:-}" ]]; then
    if grep -q '^NEKO_SHM_SIZE=' "$tmp"; then
      sed -i "s|^NEKO_SHM_SIZE=.*|NEKO_SHM_SIZE=$NEKO_SHM_SIZE|" "$tmp"
    else
      echo "NEKO_SHM_SIZE=$NEKO_SHM_SIZE" >> "$tmp"
    fi
  fi
  if [[ -n "${NEKO_DESKTOP_SCREEN:-}" ]]; then
    if grep -q '^NEKO_DESKTOP_SCREEN=' "$tmp"; then
      sed -i "s|^NEKO_DESKTOP_SCREEN=.*|NEKO_DESKTOP_SCREEN=$NEKO_DESKTOP_SCREEN|" "$tmp"
    else
      echo "NEKO_DESKTOP_SCREEN=$NEKO_DESKTOP_SCREEN" >> "$tmp"
    fi
  fi

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
  log "Starting stack on $TARGET_NAME"
  remote "mkdir -p '$DEPLOY_PATH/profile'"
  remote_root "chown -R 1000:1000 '$DEPLOY_PATH/profile'"

  local vol
  vol=$(remote_docker "docker volume ls -q --filter name=neko-farm_neko-data 2>/dev/null | head -1")
  if [[ -n "$vol" ]]; then
    if remote_root "chown -R 1000:1000 /var/lib/docker/volumes/$vol/_data" 2>/dev/null; then
      dim "volume $vol owned by 1000:1000"
    else
      warn "could not chown $vol (needs root). Neko sessions will not persist across restarts."
      warn "Fix once with: ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST 'sudo chown -R 1000:1000 /var/lib/docker/volumes/$vol/_data'"
    fi
  fi

  if [[ -f user.js ]]; then
    remote "rm -f '$DEPLOY_PATH/profile/user.js' && cp '$DEPLOY_PATH/user.js' '$DEPLOY_PATH/profile/user.js'"
    dim "user.js installed into profile"
  fi

  remote_docker "cd '$DEPLOY_PATH' && NEKO_MEM_LIMIT='${NEKO_MEM_LIMIT:-}' NEKO_SHM_SIZE='${NEKO_SHM_SIZE:-}' NEKO_DESKTOP_SCREEN='${NEKO_DESKTOP_SCREEN:-}' docker compose up -d --remove-orphans"
}

report() {
  log "Status ($TARGET_NAME)"
  remote_docker "cd '$DEPLOY_PATH' && docker compose ps" || true
  echo
  warn "Check the logs for 'neko ready':"
  dim "ssh -p $DEPLOY_PORT $DEPLOY_USER@$DEPLOY_HOST 'docker logs --tail 30 neko-farm-neko-1'"
  echo
  local hostname="${PUBLIC_HOSTNAME:-${KICK_HOSTNAME:-}}"
  if [[ -n "$hostname" ]]; then
    log "Open https://$hostname and log in with NEKO_PASSWORD from .env"
    dim "First time only: log in, sign in once, pick a low quality, and close the tab."
  fi
  warn "Media is WebRTC over TCP ${DEPLOY_HOST}:52000 (TCPMUX) and does NOT go through the tunnel."
  dim "UI loads but picture is black = TCP 52000 is blocked upstream, or VPS_PUBLIC_IP is wrong."
}

main() {
  preflight
  remote_preflight
  if [[ "$CHECK_ONLY" == true ]]; then
    log "Preflight passed for target: $TARGET_NAME"
    exit 0
  fi
  sync_files
  seed_env
  start
  report
}

main
