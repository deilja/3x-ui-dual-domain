#!/usr/bin/env bash
# Safe preflight wrapper for deilja's production servers.
# It deliberately refuses to run the upstream installer over an existing VPN
# stack or an occupied TCP/443 listener. No service/config is changed by audit.
set -Eeuo pipefail
umask 077

readonly UPSTREAM_URL="https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/3x-ui-dual-domain.sh"
readonly BACKUP_ROOT="/root/3x-ui-dual-domain-backups"
readonly PANEL_DOMAIN_DEFAULT="deilja.ru"
readonly SUBSCRIPTION_DOMAIN_DEFAULT="i.deilja.ru"
readonly PANEL_PORT_DEFAULT="1607"
readonly SUBSCRIPTION_PORT_DEFAULT="2096"
readonly REALITY_PORT_DEFAULT="4433"
readonly PANEL_PATH_DEFAULT="moscowsiti"

MODE="${1:-audit}"
case "$MODE" in audit|install|--help|-h) ;; *) echo "Usage: $0 [audit|install]" >&2; exit 2;; esac
if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  cat <<'HELP'
Usage:
  bash install-deilja-safe.sh audit    # read-only inventory
  bash install-deilja-safe.sh install # backup + safety gate + upstream install only if clean

This wrapper refuses to overwrite an existing 3x-ui/lucx-ui install, existing
VPN services, or an occupied TCP/443. It does not automatically migrate an
existing NGINX configuration: doing that safely requires a reviewed merge plan.
Defaults from deilja's current setup:
  panel domain: deilja.ru
  subscription domain: i.deilja.ru
  panel port: 1607
  subscription port: 2096
  Reality loopback port: 4433
  panel base path: moscowsiti
The upstream interactive installer still asks for its own domain values; verify
the domain roles carefully before confirming. Do not use on a production node
until the audit is reviewed.
HELP
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root." >&2; exit 1; }
command -v ss >/dev/null || { echo "ERROR: ss (iproute2) is required." >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="/root/3x-ui-dual-domain-audit-${stamp}.txt"
{
  echo "=== 3x-ui dual-domain preflight ==="
  echo "UTC: $stamp"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo "OS: $(. /etc/os-release 2>/dev/null; printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-}")"
  echo "Configured preference defaults (review, not auto-applied):"
  printf '  PANEL_DOMAIN=%s\n  SUBSCRIPTION_DOMAIN=%s\n  PANEL_PORT=%s\n  SUBSCRIPTION_PORT=%s\n  REALITY_LOOPBACK_PORT=%s\n  PANEL_BASE_PATH=%s\n' \
    "$PANEL_DOMAIN_DEFAULT" "$SUBSCRIPTION_DOMAIN_DEFAULT" "$PANEL_PORT_DEFAULT" \
    "$SUBSCRIPTION_PORT_DEFAULT" "$REALITY_PORT_DEFAULT" "$PANEL_PATH_DEFAULT"
  echo
  echo "=== Service states ==="
  for svc in nginx x-ui xray sing-box hysteria-server wg-quick@awg0; do
    printf '%-22s' "$svc"
    systemctl is-active "$svc" 2>/dev/null || true
  done
  echo
  echo "=== TCP/UDP listeners ==="
  ss -H -lntup 2>/dev/null || true
  echo
  echo "=== NGINX config test (read-only) ==="
  if command -v nginx >/dev/null; then nginx -t 2>&1 || true; else echo "nginx not installed"; fi
  echo
  echo "=== Existing install/config markers ==="
  for p in /etc/x-ui/x-ui.db /etc/x-ui/config.json /usr/local/x-ui /etc/nginx/nginx.conf /etc/nginx/stream-enabled /etc/nginx/streams-enabled /etc/nginx/conf.d; do
    [[ ! -e "$p" ]] || ls -ld "$p"
  done
  echo
  echo "=== Firewall ==="
  if command -v ufw >/dev/null; then ufw status verbose 2>&1 || true; else echo "ufw not installed"; fi
} | tee "$report"

if [[ "$MODE" == "audit" ]]; then
  echo "Audit saved: $report"
  echo "No services or configuration were changed."
  exit 0
fi

# Preserve the current state before making any change.
backup_dir="$BACKUP_ROOT/$stamp"
mkdir -p "$backup_dir"
chmod 700 "$BACKUP_ROOT" "$backup_dir"
cp -a "$report" "$backup_dir/"
for p in /etc/nginx /etc/x-ui /usr/local/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/nginx.service /etc/ufw /etc/fail2ban; do
  [[ ! -e "$p" ]] || cp -a --parents "$p" "$backup_dir/"
done
if [[ -d /etc/letsencrypt ]]; then cp -a --parents /etc/letsencrypt "$backup_dir/"; fi
if [[ -f /etc/x-ui/x-ui.db ]]; then
  sqlite3 /etc/x-ui/x-ui.db ".backup '$backup_dir/x-ui.db'" 2>/dev/null || cp -a /etc/x-ui/x-ui.db "$backup_dir/x-ui.db"
fi
tar -czf "$backup_dir/etc-configs.tar.gz" -C / "$(
  find etc/nginx etc/x-ui etc/letsencrypt etc/ufw etc/fail2ban -maxdepth 0 -type d -printf '%p ' 2>/dev/null || true
)" 2>/dev/null || true
echo "Backup created: $backup_dir"

# Hard safety gate: this upstream installer is documented for clean Ubuntu
# servers and changes the firewall and the public 443 routing architecture.
conflicts=0
if [[ -e /etc/x-ui/x-ui.db || -d /usr/local/x-ui ]]; then
  echo "BLOCKED: existing x-ui/lucx-ui installation detected; do not install over it."
  conflicts=1
fi
for svc in x-ui xray sing-box hysteria-server wg-quick@awg0; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "BLOCKED: active VPN service detected: $svc"
    conflicts=1
  fi
done
if ss -H -lntp 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
  echo "BLOCKED: TCP/443 is already occupied. Existing NGINX/Xray must be migrated with a reviewed config plan."
  ss -H -lntp 2>/dev/null | awk '$4 ~ /:443$/'
  conflicts=1
fi
if [[ $conflicts -ne 0 ]]; then
  echo "No installer was run. Backup and audit are preserved at: $backup_dir"
  exit 3
fi

echo "Safety gate passed: no known existing VPN install and TCP/443 is free."
echo "Downloading upstream installer for inspection..."
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$UPSTREAM_URL" -o "$tmp"
bash -n "$tmp"
echo "Syntax check passed. Starting upstream installer interactively."
echo "IMPORTANT: confirm domain roles; configured defaults are guidance only."
bash "$tmp" install
