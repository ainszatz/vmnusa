#!/usr/bin/env bash
# Automated installer for the Nusabackup VM Monitoring stack.
# Implements docs/deployment.md's Setup section end-to-end: installs missing
# prerequisites (Docker, python3/PyYAML), prompts for real credentials,
# validates config, then starts the stack.
#
# Usage: bash scripts/install.sh [--yes] [--skip-start] [--force]
#   --yes         skip ALL confirmation prompts (installing packages,
#                 starting the stack) — use for unattended/CI runs
#   --skip-start  do everything except starting the stack (prep + validate only)
#   --force       re-prompt for credentials even if a target file already
#                 looks filled in
#
# Prerequisite installation requires root (via sudo). promtool/amtool are
# NOT installed on the host — validation runs them via `docker run` against
# the same prom/prometheus and prom/alertmanager images docker-compose.yml
# uses, so there's never a version mismatch with the running stack.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

ASSUME_YES=0
SKIP_START=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --skip-start) SKIP_START=1 ;;
    --force) FORCE=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

confirm() {
  # confirm "Prompt text" -> 0 (yes) or 1 (no). Auto-yes if --yes given.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

replace_in_file() {
  # Literal (non-regex) string replacement, safe for secrets containing
  # sed/regex metacharacters. old/new travel via env vars (REPL_OLD/REPL_NEW),
  # not argv — argv is visible to any local user via `ps`/`/proc/<pid>/cmdline`,
  # env vars of another user's process are not.
  local file="$1"
  REPL_OLD="$2" REPL_NEW="$3" python3 - "$file" <<'PYEOF'
import os, sys
path = sys.argv[1]
old, new = os.environ["REPL_OLD"], os.environ["REPL_NEW"]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
if old not in content:
    sys.exit(f"ERROR: placeholder not found in {path}: {old!r}")
content = content.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PYEOF
}

file_contains() {
  local file="$1" needle="$2"
  grep -qF -- "$needle" "$file" 2>/dev/null
}

prompt_required() {
  # prompt_required VAR_NAME "Prompt text" ["default"]
  local __var="$1" __text="$2" __default="${3:-}"
  local __val=""
  while [ -z "$__val" ]; do
    if [ -n "$__default" ]; then
      read -r -p "$__text [$__default]: " __val
      __val="${__val:-$__default}"
    else
      read -r -p "$__text: " __val
    fi
    [ -z "$__val" ] && echo "  (nilai tidak boleh kosong)"
  done
  printf -v "$__var" '%s' "$__val"
}

prompt_secret() {
  # prompt_secret VAR_NAME "Prompt text" — requires non-empty, asks twice to confirm
  local __var="$1" __text="$2"
  local __a="" __b=""
  while true; do
    read -r -s -p "$__text: " __a; echo
    if [ -z "$__a" ]; then
      echo "  (nilai tidak boleh kosong)"
      continue
    fi
    read -r -s -p "Ulangi $__text: " __b; echo
    if [ "$__a" != "$__b" ]; then
      echo "  (tidak cocok, coba lagi)"
      continue
    fi
    break
  done
  printf -v "$__var" '%s' "$__a"
}

# ---------------------------------------------------------------------------
# OS / package manager detection
# ---------------------------------------------------------------------------

PKG_FAMILY=unknown
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) PKG_FAMILY=deb ;;
    *rhel*|*fedora*|*centos*) PKG_FAMILY=rpm ;;
  esac
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo "ERROR: script perlu root atau sudo untuk install prerequisites."; exit 1; }
  SUDO="sudo"
fi

pkg_install() {
  case "$PKG_FAMILY" in
    deb)
      $SUDO apt-get update -y
      $SUDO apt-get install -y "$@"
      ;;
    rpm)
      if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y "$@"
      else
        $SUDO yum install -y "$@"
      fi
      ;;
    *)
      echo "ERROR: distro tidak dikenali (bukan Debian/Ubuntu maupun RHEL/Fedora family)."
      echo "Install manual: $*"
      exit 1
      ;;
  esac
}

echo "== Nusabackup VM Monitoring — Automated Install =="
echo "OS family terdeteksi: $PKG_FAMILY"
echo

# ---------------------------------------------------------------------------
# 1. Prerequisites — install what's missing
# ---------------------------------------------------------------------------
echo "== Checking / installing prerequisites =="

# --- python3 + PyYAML ---
if ! command -v python3 >/dev/null 2>&1; then
  confirm "python3 tidak ditemukan. Install sekarang?" || { echo "Dibatalkan — python3 wajib."; exit 1; }
  pkg_install python3 python3-pip
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  confirm "PyYAML tidak ditemukan. Install sekarang?" || { echo "Dibatalkan — PyYAML wajib."; exit 1; }
  case "$PKG_FAMILY" in
    deb) pkg_install python3-yaml ;;
    rpm) pkg_install python3-pyyaml ;;
    *) echo "ERROR: install manual: pip3 install pyyaml"; exit 1 ;;
  esac
fi
echo "OK   python3 + PyYAML"

# --- curl (needed to fetch the Docker install script) ---
command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates

# --- Docker + Compose plugin ---
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "OK   docker + docker compose plugin sudah terinstall"
else
  confirm "Docker / docker compose plugin belum lengkap. Install via get.docker.com sekarang?" \
    || { echo "Dibatalkan — Docker wajib untuk menjalankan stack."; exit 1; }
  # Download first instead of piping straight into a root shell: an
  # interrupted/MITM'd stream can't execute partial output, and the script
  # is inspectable on disk before anything runs.
  DOCKER_INSTALL_SCRIPT="$(mktemp)"
  trap 'rm -f "$DOCKER_INSTALL_SCRIPT"' EXIT
  curl -fsSL https://get.docker.com -o "$DOCKER_INSTALL_SCRIPT"
  echo "Docker install script diunduh ke $DOCKER_INSTALL_SCRIPT — periksa dulu kalau perlu."
  confirm "Lanjutkan eksekusi script tersebut (dengan sudo)?" \
    || { echo "Dibatalkan — Docker wajib untuk menjalankan stack."; exit 1; }
  $SUDO sh "$DOCKER_INSTALL_SCRIPT"
  rm -f "$DOCKER_INSTALL_SCRIPT"
  trap - EXIT
  $SUDO systemctl enable --now docker 2>/dev/null || true
  if [ -n "$SUDO" ]; then
    $SUDO usermod -aG docker "$(id -un)" || true
    echo "NOTE: user $(id -un) ditambahkan ke group 'docker'. Perlu logout/login (atau 'newgrp docker')"
    echo "      agar bisa jalankan docker tanpa sudo di sesi berikutnya. Untuk sisa instalasi ini,"
    echo "      script akan pakai sudo bila perlu."
  fi
fi

# Decide how to invoke docker for the rest of this script: plain if the
# current session can already talk to the daemon, sudo otherwise.
if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  echo "ERROR: docker daemon tidak bisa diakses (bahkan dengan sudo). Cek 'systemctl status docker'."
  exit 1
fi
echo "OK   docker daemon reachable (pakai: ${DOCKER[*]})"
echo

# ---------------------------------------------------------------------------
# 2. Copy config templates (idempotent — never overwrite an existing file)
# ---------------------------------------------------------------------------
echo "== Copying config templates =="
copy_template() {
  local src="$1" dst="$2"
  if [ -f "$dst" ]; then
    echo "$dst sudah ada, tidak ditimpa"
  else
    cp "$src" "$dst"
    chmod 600 "$dst"
    echo "created $dst (mode 600)"
  fi
}
copy_template .env.example .env
copy_template prometheus/pve.yml.example prometheus/pve.yml
copy_template alertmanager/alertmanager.yml.example alertmanager/alertmanager.yml
# Also lock down files that already existed (e.g. hand-copied per docs)
# before credentials get written into them below.
chmod 600 .env prometheus/pve.yml alertmanager/alertmanager.yml
echo

# ---------------------------------------------------------------------------
# 3. Interactive credential prompts (only for placeholders still present)
# ---------------------------------------------------------------------------
echo "== Configuring credentials =="

# --- Grafana admin ---
if [ "$FORCE" -eq 1 ] || grep -q "^GRAFANA_ADMIN_PASSWORD=$" .env 2>/dev/null; then
  echo "-- Grafana admin"
  prompt_required GRAFANA_USER "Grafana admin username" "admin"
  prompt_secret GRAFANA_PASS "Grafana admin password"
  replace_in_file .env "GRAFANA_ADMIN_USER=admin" "GRAFANA_ADMIN_USER=${GRAFANA_USER}" || true
  replace_in_file .env "GRAFANA_ADMIN_PASSWORD=" "GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASS}"
else
  echo "-- Grafana admin password sudah diisi, skip. (pakai --force untuk isi ulang)"
fi

# --- Proxmox API token (prometheus/pve.yml) ---
if [ "$FORCE" -eq 1 ] || file_contains prometheus/pve.yml "changeme-uuid-token"; then
  echo "-- Proxmox API token (role PVEAuditor, read-only)"
  prompt_required PVE_USER "Proxmox token user (mis. monitoring@pve)" "monitoring@pve"
  prompt_required PVE_TOKEN_NAME "Proxmox token name" "prometheus"
  prompt_secret PVE_TOKEN_VALUE "Proxmox token value (UUID)"
  replace_in_file prometheus/pve.yml "user: monitoring@pve" "user: ${PVE_USER}"
  replace_in_file prometheus/pve.yml "token_name: prometheus" "token_name: ${PVE_TOKEN_NAME}"
  replace_in_file prometheus/pve.yml "token_value: changeme-uuid-token" "token_value: ${PVE_TOKEN_VALUE}"
else
  echo "-- prometheus/pve.yml sudah diisi, skip. (pakai --force untuk isi ulang)"
fi

# --- Proxmox host (prometheus/prometheus.yml — not a .example, edited in place) ---
if [ "$FORCE" -eq 1 ] || file_contains prometheus/prometheus.yml "pve1.example.local"; then
  echo "-- Proxmox host (job 'pve' di prometheus/prometheus.yml)"
  prompt_required PVE_HOST "Hostname/IP node Proxmox asli"
  replace_in_file prometheus/prometheus.yml "pve1.example.local" "${PVE_HOST}"
else
  echo "-- prometheus/prometheus.yml sudah diisi, skip. (pakai --force untuk isi ulang)"
fi

# --- Telegram (alertmanager/alertmanager.yml) ---
if [ "$FORCE" -eq 1 ] || file_contains alertmanager/alertmanager.yml "changeme-bot-token"; then
  echo "-- Telegram bot"
  prompt_secret TG_BOT_TOKEN "Telegram bot token"
  prompt_required TG_CHAT_CRITICAL "Chat ID untuk alert critical"
  read -r -p "Chat ID untuk alert warning sama dengan critical? [Y/n]: " same_chat
  if [[ "$same_chat" =~ ^[Nn]$ ]]; then
    prompt_required TG_CHAT_WARNING "Chat ID untuk alert warning"
  else
    TG_CHAT_WARNING="$TG_CHAT_CRITICAL"
  fi
  # Two occurrences each of bot_token/chat_id (critical then warning receiver).
  replace_in_file alertmanager/alertmanager.yml 'bot_token: "changeme-bot-token"' "bot_token: \"${TG_BOT_TOKEN}\""
  replace_in_file alertmanager/alertmanager.yml 'bot_token: "changeme-bot-token"' "bot_token: \"${TG_BOT_TOKEN}\""
  replace_in_file alertmanager/alertmanager.yml 'chat_id: 000000000' "chat_id: ${TG_CHAT_CRITICAL}"
  replace_in_file alertmanager/alertmanager.yml 'chat_id: 000000000' "chat_id: ${TG_CHAT_WARNING}"
else
  echo "-- alertmanager/alertmanager.yml sudah diisi, skip. (pakai --force untuk isi ulang)"
fi
echo

# ---------------------------------------------------------------------------
# 4. Validate config
# ---------------------------------------------------------------------------
echo "== Validating config =="
bash scripts/validate.sh
echo

"${DOCKER[@]}" compose config >/dev/null
echo "OK   docker compose config"

# promtool/amtool: run via the same images docker-compose.yml uses, so
# validation always matches what actually gets deployed — no separate
# host install, no version drift.
"${DOCKER[@]}" run --rm -v "$(pwd)/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool prom/prometheus:latest \
  check config /etc/prometheus/prometheus.yml
echo "OK   promtool check config"

"${DOCKER[@]}" run --rm -v "$(pwd)/prometheus:/etc/prometheus:ro" \
  --entrypoint sh prom/prometheus:latest \
  -c "promtool check rules /etc/prometheus/rules/*.yml"
echo "OK   promtool check rules"

"${DOCKER[@]}" run --rm -v "$(pwd)/alertmanager:/etc/alertmanager:ro" \
  --entrypoint amtool prom/alertmanager:latest \
  check-config /etc/alertmanager/alertmanager.yml
echo "OK   amtool check-config"

echo "All checks passed."
echo

if [ "$SKIP_START" -eq 1 ]; then
  echo "--skip-start diberikan, tidak menjalankan stack. Jalankan 'docker compose up -d' manual saat siap."
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. Start the stack
# ---------------------------------------------------------------------------
if ! confirm "Jalankan 'docker compose up -d' sekarang?"; then
  echo "Dibatalkan. Jalankan 'docker compose up -d' manual saat siap."
  exit 0
fi

echo "== Starting stack =="
"${DOCKER[@]}" compose up -d
echo

# ---------------------------------------------------------------------------
# 6. Post-install checklist
# ---------------------------------------------------------------------------
cat <<'EOF'
== Stack started. Verifikasi (lihat docs/deployment.md untuk detail) ==

- Prometheus (loopback-only, port 9090):
    curl http://127.0.0.1:9090/-/healthy   # dari monitoring VM langsung
  Dari luar: ssh -L 9090:127.0.0.1:9090 user@monitoring-vm, lalu buka
  http://localhost:9090 -> Status -> Targets -> pastikan job prometheus/pve/node/backup UP.

- Grafana: http://<monitoring-vm>:3000 (login GRAFANA_ADMIN_USER/PASSWORD dari .env)
    -> Connections -> Data sources -> pastikan datasource Prometheus "working"
    -> Dashboards -> folder "Nusabackup Monitoring":
       - VM Detail: harus ada data CPU/mem/disk dalam ~1 scrape interval (30s)
       - Backup Job Status: KOSONG itu normal sampai backup-job-exporter terhubung
       - Storage Capacity: data langsung ada; panel prediksi butuh beberapa jam untuk akurat

- Alertmanager (loopback-only, port 9093):
    ssh -L 9093:127.0.0.1:9093 user@monitoring-vm, buka http://localhost:9093
    -> pastikan Status: config ter-load tanpa error.

- Prometheus UI -> Alerts: pastikan semua rule group (resource, storage,
  backup-job, service-health) ter-load tanpa error merah. "inactive" = normal.

- Firewall: batasi port 3000 (Grafana) ke subnet/VPN ops saja — lihat
  docs/deployment.md bagian Firewall / Akses untuk contoh ufw/nftables.

- Test alert (opsional):
    docker compose exec alertmanager amtool alert add alertname=TestAlert \
      severity=warning --alertmanager.url=http://localhost:9093
  Cek pesan masuk ke Telegram dalam ~30 detik.

- Kalau Docker baru diinstall di sesi ini: logout/login (atau 'newgrp docker')
  supaya bisa jalankan 'docker compose ...' tanpa sudo di sesi berikutnya.

Baca docs/handover.md sebelum go-live produksi (known limitations & open questions).
EOF
