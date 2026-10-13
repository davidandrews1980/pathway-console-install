#!/usr/bin/env bash
# Pathway Developer's Console - Docker installer (Ubuntu/Debian, arm64 or amd64).
#   curl -fsSL https://github.com/davidandrews1980/pathway-console-install/releases/latest/download/install.sh | sudo bash
# Env overrides: APP_PORT (default 80), INSTALL_DIR (default /opt/pathway-console), BUNDLE_URL, SKIP_FIREWALL=1
set -euo pipefail
APP_PORT="${APP_PORT:-80}"
INSTALL_DIR="${INSTALL_DIR:-/opt/pathway-console}"
BUNDLE_URL="${BUNDLE_URL:-https://github.com/davidandrews1980/pathway-console-install/releases/latest/download/pathway-console.tar.gz}"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL ... | sudo bash"
command -v docker >/dev/null || die "docker not found (install Docker first)"
docker info >/dev/null 2>&1 || die "docker daemon not running (systemctl start docker)"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing (apt-get install docker-compose-plugin)"

need=(); for c in git curl openssl tar; do command -v $c >/dev/null || need+=("$c"); done
if [ ${#need[@]} -gt 0 ]; then log "Installing ${need[*]}"; apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}"; fi

log "Downloading bundle to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"; tmp=$(mktemp)
curl -fsSL --retry 3 "$BUNDLE_URL" -o "$tmp" || die "download failed: $BUNDLE_URL"
tar -xzf "$tmp" -C "$INSTALL_DIR" --strip-components=1; rm -f "$tmp"
cd "$INSTALL_DIR"

PUBLIC_IP=$(curl -fs4 --max-time 5 https://ifconfig.me || curl -fs4 --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')
HOSTPART="$PUBLIC_IP"; [ "$APP_PORT" = 80 ] || HOSTPART="$PUBLIC_IP:$APP_PORT"

if [ ! -f .env ]; then
  log "Generating secrets into $INSTALL_DIR/.env (chmod 600)"
  umask 077
  cat > .env <<ENV
MONGO_USER=pathway_admin
MONGO_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
EXPORT_TOKEN=$(openssl rand -hex 24)
APP_PORT=$APP_PORT
CORS_ORIGINS=http://$HOSTPART
# Optional, fill in later then run: docker compose up -d
DEEPSEEK_API_KEY=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
ENV
else
  log "Keeping existing .env (secrets unchanged)"
  sed -i "s/^APP_PORT=.*/APP_PORT=$APP_PORT/" .env
fi
chmod 600 .env

if [ "${SKIP_FIREWALL:-0}" != 1 ] && command -v iptables >/dev/null; then
  log "Opening ports 80, 443, $APP_PORT in iptables (Oracle Ubuntu images block them by default)"
  for p in 80 443 "$APP_PORT"; do
    iptables -C INPUT -p tcp -m state --state NEW --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 6 -p tcp -m state --state NEW --dport "$p" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp -m state --state NEW --dport "$p" -j ACCEPT
  done
  if ! command -v netfilter-persistent >/dev/null; then
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
  fi
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi

log "Building and starting containers (first build takes ~10-20 min on a small VM)"
docker compose up -d --build

log "Waiting for the app to become healthy"
ok=0
for _ in $(seq 1 120); do
  if curl -fs "http://127.0.0.1:$APP_PORT/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 5
done
[ $ok = 1 ] || { docker compose ps; docker compose logs --tail=50 backend; die "app did not become healthy in 10 min"; }
curl -fs "http://127.0.0.1:$APP_PORT/api/health"; echo

cat <<MSG

==============================================================
 Pathway Developer's Console is running
   URL:  http://$HOSTPART
 First run: open the URL and tap "Sign up" / create an account.
   There is no preset admin password; the first account you
   create is yours. Each user's terminal runs sandboxed.
 Secrets: $INSTALL_DIR/.env (generated here, chmod 600)
 Add an AI key later: edit DEEPSEEK_API_KEY in that file, then
   cd $INSTALL_DIR && docker compose up -d
 Logs: cd $INSTALL_DIR && docker compose logs -f
 Can't reach it from your phone? Open ports 80/443 (and $APP_PORT)
   in the Oracle Cloud security list (see instructions).
==============================================================
MSG
