#!/usr/bin/env bash
# Rebuild Jellyfin for Tizen and (re)install it on a Samsung TV.
#
# Usage: ./deploy.sh [options]
#   --skip-web      Reuse existing jellyfin-web/dist (skip the slow web build)
#   --web-ref REF   Check out jellyfin-web tag/branch REF first (e.g. v12.4)
#   --no-launch     Install only, don't launch the app afterwards
#   -h, --help      Show this help
#
# Environment overrides:
#   TV_IP         TV address                        (default 192.168.2.205)
#   WEB_DIR       jellyfin-web checkout             (default ../jellyfin-web)
#   NODE_VERSION  Node version used via `nvm exec`  (default WEB_DIR/.nvmrc, else 24)
#   CERT_PROFILE  Tizen certificate profile         (default: active profile)
#   TIZEN_HOME    Tizen Studio install              (default ~/tizen-studio)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TV_IP="${TV_IP:-192.168.2.205}"
WEB_DIR="${WEB_DIR:-$SCRIPT_DIR/../jellyfin-web}"
TIZEN_HOME="${TIZEN_HOME:-$HOME/tizen-studio}"
CERT_PROFILE="${CERT_PROFILE:-}"
SKIP_WEB=0
WEB_REF=""
LAUNCH=1

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-web) SKIP_WEB=1 ;;
        --web-ref) [ $# -ge 2 ] || die "--web-ref needs a value"; WEB_REF="$2"; shift ;;
        --no-launch) LAUNCH=0 ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

[ -d "$WEB_DIR" ] || die "jellyfin-web not found at $WEB_DIR (set WEB_DIR)"
WEB_DIR="$(cd "$WEB_DIR" && pwd)"

# --- Node via nvm (temporary switch; never touches the default version) ---
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] || die "nvm not found at $NVM_DIR"
set +eu; . "$NVM_DIR/nvm.sh"; set -eu

if [ -z "${NODE_VERSION:-}" ]; then
    if [ -s "$WEB_DIR/.nvmrc" ]; then NODE_VERSION="$(tr -d '[:space:]' < "$WEB_DIR/.nvmrc")"; else NODE_VERSION=24; fi
fi

run_node() { (set +eu; nvm exec --silent "$NODE_VERSION" "$@"); }

if [ "$(set +eu; nvm version "$NODE_VERSION")" = "N/A" ]; then
    log "Installing Node $NODE_VERSION via nvm"
    (set +eu; nvm install "$NODE_VERSION")
fi

# npm ci only when node_modules is missing or package-lock.json changed since last install
npm_install_needed() {
    [ ! -f "$1/node_modules/.package-lock.json" ] || [ "$1/package-lock.json" -nt "$1/node_modules/.package-lock.json" ]
}

# --- 1. jellyfin-web ---
if [ -n "$WEB_REF" ]; then
    log "Checking out jellyfin-web $WEB_REF"
    git -C "$WEB_DIR" fetch --depth 1 origin "$WEB_REF"
    git -C "$WEB_DIR" checkout --detach FETCH_HEAD
    SKIP_WEB=0
fi

if [ "$SKIP_WEB" -eq 1 ]; then
    [ -f "$WEB_DIR/dist/index.html" ] || die "--skip-web given but $WEB_DIR/dist is missing"
    log "Skipping jellyfin-web build (reusing dist)"
else
    log "Building jellyfin-web $(git -C "$WEB_DIR" describe --tags --always 2>/dev/null) with Node $NODE_VERSION"
    if npm_install_needed "$WEB_DIR"; then
        (cd "$WEB_DIR" && run_node npm ci --no-audit)
    fi
    (cd "$WEB_DIR" && run_node env USE_SYSTEM_FONTS=1 npm run build:production)
fi

# --- 2. www/ ---
log "Preparing www/"
cd "$SCRIPT_DIR"
if npm_install_needed "$SCRIPT_DIR"; then
    run_node env JELLYFIN_WEB_DIR="$WEB_DIR/dist" npm ci --no-audit   # postinstall runs gulp
else
    run_node env JELLYFIN_WEB_DIR="$WEB_DIR/dist" npm run build
fi
[ -f www/index.html ] || die "www/index.html was not generated"

# --- 3. Package .wgt ---
export PATH="$TIZEN_HOME/tools:$TIZEN_HOME/tools/ide/bin:$PATH"
command -v tizen >/dev/null || die "tizen CLI not found under $TIZEN_HOME"
command -v sdb >/dev/null || die "sdb not found under $TIZEN_HOME"

log "Building and signing .wgt"
rm -rf .buildResult ./*.wgt
tizen build-web -e ".*" -e gulpfile.babel.js -e README.md -e LICENSE -e "*.sh" \
    -e "node_modules/*" -e "package*.json" -e "yarn.lock" < /dev/null
[ -d .buildResult ] || die "tizen build-web failed"
if [ -n "$CERT_PROFILE" ]; then
    tizen package -t wgt -s "$CERT_PROFILE" -o . -- .buildResult < /dev/null
else
    tizen package -t wgt -o . -- .buildResult < /dev/null
fi
WGT="$(ls -t ./*.wgt 2>/dev/null | head -n 1)"
[ -n "$WGT" ] || die "tizen package produced no .wgt"

# --- 4. Install on TV ---
log "Connecting to TV at $TV_IP"
TARGET=""
for attempt in 1 2 3; do
    sdb connect "$TV_IP" || true
    TARGET="$(sdb devices | awk -v s="$TV_IP:26101" '$1 == s && $2 == "device" { print $3 }')"
    [ -n "$TARGET" ] && break
    sleep 2
done
[ -n "$TARGET" ] || die "Can't reach TV at $TV_IP. Is it on, with Developer Mode enabled and Host PC IP set to this Mac?"
echo "Target: $TARGET"

# Needed for Samsung certificates; harmless to repeat
tizen install-permit -t "$TARGET" < /dev/null || true

log "Installing $WGT"
out="$(tizen install -n "$WGT" -t "$TARGET" < /dev/null 2>&1)" || true
printf '%s\n' "$out" | grep -v 'installing\[' || true
printf '%s\n' "$out" | grep -q "successfully installed" || die "Install failed"

if [ "$LAUNCH" -eq 1 ]; then
    APP_ID="$(sed -n 's/.*tizen:application id="\([^"]*\)".*/\1/p' config.xml)"
    log "Launching $APP_ID"
    tizen run -p "$APP_ID" -t "$TARGET" < /dev/null
fi

log "Done"
