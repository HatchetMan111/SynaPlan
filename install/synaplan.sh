#!/usr/bin/env bash
#
# Synaplan Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Synaplan – AI Control Plane (Server-Mode Prod, Web UI :8000)
# Upstream: https://github.com/metadist/synaplan
# Stack:    FrankenPHP/Symfony + Vue (published Docker-Image) + MariaDB + Redis
# Läuft:    vollständig lokal im LXC, keine Cloud nötig
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SynaPlan/main/install/synaplan.sh)"
#   CT_ID=101 CORES=4 RAM=8192 DISK=30 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SynaPlan/main/install/synaplan.sh)"
#   bash synaplan.sh --ctid 101 --cores 4 --memory 8192 --disk 30 --bridge vmbr0 --debug
#
# Hinweis: Synaplan braucht offiziell 8 GB RAM (~4 GB Images). Darum Default
# 4 vCPU / 8192 MB / 30 GB – KEIN 1-2-GB-Standard. Darunter wird gewarnt.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="synaplan"                                # Container-Hostname + Service-Name
PORT="8000"                                   # Synaplan Web UI (deploy: SYNAPLAN_HTTP_PORT)
UPSTREAM_REPO="https://github.com/metadist/synaplan.git"
UPSTREAM_BRANCH="main"
RELEASES_API="https://api.github.com/repos/metadist/synaplan/releases/latest"
REPO_RAW_BASE="https://raw.githubusercontent.com/HatchetMan111/SynaPlan/main"

DEFAULT_CORES="4"                             # vCPU (Synaplan-Empfehlung: 4+, Minimum 2)
DEFAULT_RAM="8192"                            # RAM in MB (Upstream-Minimum 8192)
DEFAULT_SWAP="1024"                           # Swap (MB)
DEFAULT_DISK="30"                             # Disk in GB (Images ~4 GB + DB + Daten, min. 20)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-12-standard"               # Template-Familie (Docker-getestet)
DEFAULT_ADMIN_EMAIL="admin@synaplan.local"    # Erst-Admin (nur im LXC)
UNPRIVILEGED="1"
FEATURES="nesting=1,keyctl=1"                 # nesting/keyctl = Docker im LXC nötig

# Umgebungs-Overrides erlauben: CT_ID=101 CORES=4 RAM=8192 DISK=30 ./synaplan.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
ADMIN_EMAIL_ARG="${ADMIN_EMAIL:-}"
ADMIN_PASSWORD_ARG="${ADMIN_PASSWORD:-}"
VERSION_ARG="${VERSION:-}"
DOMAIN_ARG="${DOMAIN:-}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"
SCRIPT_ARGS="$*"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe zusätzlich ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash synaplan.sh [OPTIONEN]
  CT_ID=101 bash synaplan.sh
  bash -c "\$(wget -qLO - ${REPO_RAW_BASE}/install/synaplan.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM}, Minimum 8192 laut Upstream)
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK}, Minimum 20 empfohlen)
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --admin-email MAIL   Erst-Admin-Mail (Default: ${DEFAULT_ADMIN_EMAIL})
  --admin-password PW  Erst-Admin-Passwort (Default: zufällig, 32 Hex-Zeichen; lieber als ENV ADMIN_PASSWORD)
  --version X.Y.Z      Synaplan-Version pinnen (Default: neuester GitHub-Release)
  --domain URL         APP_URL/FRONTEND_URL überschreiben, z. B. https://ai.example.com
                       (Default: http://<LXC-IP>:${PORT})
  --debug, -x          set -x + maximale Fehlermeldungskette
  --help, -h           diese Hilfe

Nach der Installation:
  Web UI:   http://<LXC-IP>:${PORT}
  API-Docs: http://<LXC-IP>:${PORT}/api/doc
  Login:    ${DEFAULT_ADMIN_EMAIL} (Passwort wird am Ende angezeigt)
EOF
}

# ---------------------------------------------------------------------------
# Debugging: komplette Fehlermeldungskette (Stacktrace, stderr/stdout, Exit-Code, Logs)
# ---------------------------------------------------------------------------
on_error() {
  local exit_code="$1" lineno="$2" cmd="$3"
  set +x
  # Sehr lange Befehle (z. B. Heredoc-Blöcke) kürzen – das Log enthält alles.
  if ((${#cmd} > 2000)); then
    cmd="${cmd:0:2000}… [gekürzt, vollständiger Befehl in $LOG_FILE]"
  fi
  echo ""
  msg_error "════════════ INSTALLATION FEHLGESCHLAGEN ════════════"
  msg_error "Befehl    : $cmd"
  msg_error "Zeile     : $lineno"
  msg_error "Exit-Code : $exit_code"
  msg_error "Args      : $SCRIPT_ARGS"
  msg_error "Logdatei  : $LOG_FILE (komplette stdout/stderr-Kette)"
  echo ""
  msg_error "--- Stacktrace (neuester Aufruf zuerst) ---"
  local i=0
  while caller "$i"; do ((i++)) || true; done
  echo ""
  if command -v pct >/dev/null 2>&1 && [[ -n "${CTID:-}" ]]; then
    msg_error "--- pct config ${CTID} ---"
    pct config "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- pct status ${CTID} ---"
    pct status "${CTID}" 2>&1 || true
    echo ""
    msg_error "--- systemctl status im Container (synaplan) ---"
    pct exec "${CTID}" -- systemctl status "${APP}" --no-pager --full 2>&1 || true
    echo ""
    msg_error "--- journalctl im Container (synaplan, letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- journalctl -u "${APP}" --no-pager -n 100 2>&1 || true
    echo ""
    msg_error "--- docker ps im Container ---"
    pct exec "${CTID}" -- docker ps -a 2>&1 || true
    echo ""
    msg_error "--- docker compose logs (letzte 100 Zeilen) ---"
    pct exec "${CTID}" -- docker compose -f /opt/synaplan/deploy/compose.yaml logs --tail=100 --no-color 2>&1 || true
  fi
  echo ""
  msg_error "Re-run mit vollem Trace:"
  # shellcheck disable=SC2086
  msg_error "  bash -x synaplan.sh $SCRIPT_ARGS"
  msg_error "  oder: DEBUG=1 bash synaplan.sh $SCRIPT_ARGS"
  msg_error "Bitte bei Fehlermeldungen IMMER die komplette Logdatei ($LOG_FILE) mitschicken."
  exit "$exit_code"
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CTID="$CT_ID_ARG"
HOSTNAME_ARG="$APP"
CORES="$CORES_ARG"
RAM="$RAM_ARG"
DISK="$DISK_ARG"
STORAGE_ARG=""
TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE"
BRIDGE="$DEFAULT_BRIDGE"
ROOT_PASSWORD=""
SSH_KEY=""
ADMIN_EMAIL="$ADMIN_EMAIL_ARG"
ADMIN_PASSWORD="$ADMIN_PASSWORD_ARG"
PIN_VERSION="$VERSION_ARG"
DOMAIN="$DOMAIN_ARG"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid)            CTID="$2"; shift 2 ;;
    --hostname)        HOSTNAME_ARG="$2"; shift 2 ;;
    --cores)           CORES="$2"; shift 2 ;;
    --memory)          RAM="$2"; shift 2 ;;
    --disk)            DISK="$2"; shift 2 ;;
    --storage)         STORAGE_ARG="$2"; shift 2 ;;
    --template-store)  TEMPLATE_STORE="$2"; shift 2 ;;
    --bridge)          BRIDGE="$2"; shift 2 ;;
    --password)        ROOT_PASSWORD="$2"; shift 2 ;;
    --ssh-key)         SSH_KEY="$2"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --version)         PIN_VERSION="$2"; shift 2 ;;
    --domain)          DOMAIN="$2"; shift 2 ;;
    --debug|-x)        DEBUG="1"; set -x; shift ;;
    --help|-h)         usage; exit 0 ;;
    *)                 msg_error "Unbekannte Option: $1 (siehe --help)"; exit 9 ;;
  esac
done

[[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"
CT_IP=""
SYNAPLAN_VERSION=""
STORAGE=""
TEMPLATE=""

# ---------------------------------------------------------------------------
# Host-Teil: Preflight, Storage/Template, CT-Erstellung, IP (Task 3)
# ---------------------------------------------------------------------------
preflight() {
  [[ "$(id -u)" -eq 0 ]] || { msg_error "Als root auf dem Proxmox-Host ausführen."; exit 1; }
  for bin in pct pveam pvesh wget openssl; do
    command -v "$bin" >/dev/null 2>&1 || { msg_error "'$bin' fehlt. Auf Proxmox-Host laufen lassen."; exit 2; }
  done
  if [[ -z "$CTID" ]]; then CTID="$(pvesh get /cluster/nextid)"; msg_info "CT-ID: nächste freie ID = $CTID"; fi
  if [[ "$RAM" -lt 6144 ]]; then msg_warn "RAM ${RAM} MB < 6144 MB – Synaplan braucht offiziell 8 GB. OOM möglich."; fi
  if [[ "$DISK" -lt 20 ]]; then msg_warn "Disk ${DISK} GB < 20 GB – Images (~4 GB) + DB brauchen Platz."; fi
}

# Werte, die per sed in deploy/.env interpoliert werden, duerfen keine
# sed-/Shell-Sonderzeichen enthalten (sonst korrupte .env oder Injection).
validate_inputs() {
  case "$ADMIN_EMAIL" in *@*.*) ;; *) msg_error "ADMIN_EMAIL ung\u00fcltig: $ADMIN_EMAIL"; exit 10 ;; esac
  local v="$ADMIN_EMAIL${DOMAIN:-}"
  local stripped="${v//[A-Za-z0-9@._:+\/\-]/}"
  [[ -z "$stripped" ]] || { msg_error "ADMIN_EMAIL/DOMAIN enthalten unzul\u00e4ssige Zeichen."; exit 10; }
  if [[ -n "${ADMIN_PASSWORD_ARG:-}" ]] && [[ ! "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9._-]+$ ]]; then
    msg_error "Eigenes ADMIN_PASSWORD: nur Buchstaben/Ziffern sowie . _ - erlaubt (sed-sicher)."; exit 10
  fi
}

pick_storage() {
  if [[ -n "$STORAGE_ARG" ]]; then STORAGE="$STORAGE_ARG"; return; fi
  if pvesm status 2>/dev/null | awk '$2=="dir" || $2=="lvmthin" || $2=="zfspool" {print $1}' | grep -qx "local-lvm"; then STORAGE="local-lvm"; return; fi
  STORAGE="$(pvesm status 2>/dev/null | awk '$3 ~ /rootdir/ || $2=="dir" {print $1}' | head -1)"
  [[ -n "${STORAGE:-}" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 3; }
  msg_info "RootFS-Storage: $STORAGE"
}

pick_template() {
  local avail=""
  avail="$(pveam available --section system 2>/dev/null | grep -o "${DEFAULT_OS}[^\"]*amd64.tar.zst" | sort -V | tail -1 || true)"
  if [[ -z "$avail" ]]; then avail="$(pveam available --section system 2>/dev/null | grep -o "${DEFAULT_OS}[^\"]*amd64.tar.gz" | sort -V | tail -1 || true)"; fi
  [[ -n "$avail" ]] || { msg_error "Kein ${DEFAULT_OS}-Template gefunden."; exit 4; }
  if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$DEFAULT_OS"; then
    msg_info "Lade Template $avail ..."
    pveam download "$TEMPLATE_STORE" "$avail"
  fi
  TEMPLATE="$(pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -o "[^ ]*${DEFAULT_OS}[^ ]*" | sort -V | tail -1)"
  [[ -n "$TEMPLATE" ]] || { msg_error "Template-Liste leer nach Download."; exit 4; }
  msg_info "Template: $TEMPLATE"
}

create_ct() {
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_info "CT $CTID existiert – Re-Run (idempotent), kein neues pct create."
    pct start "$CTID" 2>/dev/null || true
    return
  fi
  [[ -z "${ROOT_PASSWORD:-}" ]] && ROOT_PASSWORD="$(openssl rand -hex 12)"
  local ssh_opt=()
  [[ -n "${SSH_KEY:-}" ]] && ssh_opt=(--ssh-public-keys "$SSH_KEY")
  pct create "$CTID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE##*/}" \
    --hostname "$HOSTNAME_ARG" --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE}:${DISK}" --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" --onboot 1 --password "$ROOT_PASSWORD" \
    "${ssh_opt[@]}"
  pct start "$CTID"
  sleep 5
  msg_ok "Container CT $CTID ($HOSTNAME_ARG) erstellt und gestartet."
}

get_ct_ip() {
  local ip="" i=0
  while [[ $i -lt 30 ]]; do
    ip="$(pct exec "$CTID" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    [[ -n "$ip" ]] && { CT_IP="$ip"; msg_ok "Container-IP: $CT_IP"; return 0; }
    sleep 5; i=$((i+1))
  done
  msg_error "Keine DHCP-IP für CT $CTID nach 150 s."; exit 5
}

# ---------------------------------------------------------------------------
# LXC-Teil: Docker, Clone, deploy/.env, Lifecycle, systemd (Task 4)
# ---------------------------------------------------------------------------
setup_lxc() {
  pct exec "$CTID" -- bash -c 'set -euo pipefail; apt-get update; apt-get install -y ca-certificates curl gnupg git openssl iproute2;
    install -m 0755 -d /etc/apt/keyrings;
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg;
    echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list;
    apt-get update; apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin;
    docker --version; docker compose version'
  pct exec "$CTID" -- bash -c 'set -euo pipefail; if [ -d /opt/synaplan/.git ]; then git -C /opt/synaplan fetch --depth 1 origin "$0"; git -C /opt/synaplan reset --hard FETCH_HEAD; else git clone --depth 1 --branch "'"$UPSTREAM_BRANCH"'" "'"$UPSTREAM_REPO"'" /opt/synaplan; fi' "$UPSTREAM_BRANCH"
  msg_ok "Docker + Synaplan-Checkout bereit."
}

resolve_version() {
  if [[ -n "$PIN_VERSION" ]]; then SYNAPLAN_VERSION="$PIN_VERSION"; return; fi
  SYNAPLAN_VERSION="$(curl -fsSL "$RELEASES_API" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -z "${SYNAPLAN_VERSION:-}" ]]; then SYNAPLAN_VERSION="1.0.0"; msg_warn "Release-API offline – Fallback SYNAPLAN_VERSION=1.0.0."; fi
  msg_info "SYNAPLAN_VERSION=$SYNAPLAN_VERSION"
}

url_base() {
  if [[ -n "${DOMAIN:-}" ]]; then
    case "$DOMAIN" in
      https://*) ;;
      http://*) msg_warn "Plain-http-Domain konfiguriert – vor echten Nutzern HTTPS-Proxy davor." ;;
      *) msg_error "DOMAIN muss mit https:// beginnen (ist: $DOMAIN)."; exit 8 ;;
    esac
    printf '%s' "$DOMAIN"
  else
    printf 'http://%s:%s' "$CT_IP" "$PORT"
  fi
}

write_env() {
  local base="$1"
  local env_file="/opt/synaplan/deploy/.env"
  if pct exec "$CTID" -- test -f "$env_file"; then
    msg_info "deploy/.env existiert – Secrets bleiben, aktualisiere nur IP/Version."
    pct exec "$CTID" -- bash -c 'set -euo pipefail; cd /opt/synaplan/deploy;
      sed -i "s|^APP_URL=.*|APP_URL='"$base"'|; s|^FRONTEND_URL=.*|FRONTEND_URL='"$base"'|" .env;
      sed -i "s|^SYNAPLAN_VERSION=.*|SYNAPLAN_VERSION='"$SYNAPLAN_VERSION"'|" .env;
      grep -q "^SYNAPLAN_HTTP_BIND=" .env && sed -i "s|^SYNAPLAN_HTTP_BIND=.*|SYNAPLAN_HTTP_BIND=0.0.0.0|" .env || echo "SYNAPLAN_HTTP_BIND=0.0.0.0" >> .env;
      grep -q "^SYNAPLAN_HTTP_PORT=" .env && sed -i "s|^SYNAPLAN_HTTP_PORT=.*|SYNAPLAN_HTTP_PORT='"$PORT"'|" .env || echo "SYNAPLAN_HTTP_PORT='"$PORT"'" >> .env'
    return
  fi
  [[ -z "${ADMIN_PASSWORD:-}" ]] && ADMIN_PASSWORD="$(openssl rand -hex 16)"
  local pwlen=${#ADMIN_PASSWORD}
  if [[ "$pwlen" -lt 8 || "$pwlen" -gt 64 ]]; then msg_error "Admin-Passwort muss 8-64 Zeichen haben (ist $pwlen)."; exit 6; fi
  msg_info "Admin-Passwort-Länge: $pwlen Zeichen (Wert nur in Final-Box)."
  pct exec "$CTID" -- bash -c 'set -euo pipefail; cd /opt/synaplan;
    [ -f deploy/selfhost.env.example ] || { echo "selfhost.env.example fehlt" >&2; exit 7; };
    sed -e "s|^APP_SECRET=.*|APP_SECRET=|" -e "s|^TOKEN_SECRET=.*|TOKEN_SECRET=|" \
        -e "s|^MARIADB_PASSWORD=.*|MARIADB_PASSWORD=|" -e "s|^MARIADB_ROOT_PASSWORD=.*|MARIADB_ROOT_PASSWORD=|" \
        -e "s|^REALTIME_API_KEY=.*|REALTIME_API_KEY=|" -e "s|^REALTIME_TOKEN_SECRET=.*|REALTIME_TOKEN_SECRET=|" \
        -e "s|^REALTIME_ADMIN_PASSWORD=.*|REALTIME_ADMIN_PASSWORD=|" -e "s|^REALTIME_ADMIN_SECRET=.*|REALTIME_ADMIN_SECRET=|" \
        -e "s|^APP_URL=.*|APP_URL='"$base"'|" \
        -e "s|^FRONTEND_URL=.*|FRONTEND_URL='"$base"'|" \
        -e "s|^BOOTSTRAP_ADMIN_EMAIL=.*|BOOTSTRAP_ADMIN_EMAIL='"$ADMIN_EMAIL"'|" \
        -e "s|^BOOTSTRAP_ADMIN_PASSWORD=.*|BOOTSTRAP_ADMIN_PASSWORD='"$ADMIN_PASSWORD"'|" \
        deploy/selfhost.env.example > deploy/.env;
    sed -i "s|^SYNAPLAN_VERSION=.*|SYNAPLAN_VERSION='"$SYNAPLAN_VERSION"'|" deploy/.env;
    grep -q "^SYNAPLAN_HTTP_BIND=" deploy/.env && sed -i "s|^SYNAPLAN_HTTP_BIND=.*|SYNAPLAN_HTTP_BIND=0.0.0.0|" deploy/.env || echo "SYNAPLAN_HTTP_BIND=0.0.0.0" >> deploy/.env;
    grep -q "^SYNAPLAN_HTTP_PORT=" deploy/.env && sed -i "s|^SYNAPLAN_HTTP_PORT=.*|SYNAPLAN_HTTP_PORT='"$PORT"'|" deploy/.env || echo "SYNAPLAN_HTTP_PORT='"$PORT"'" >> deploy/.env;
    grep -q "^BOOTSTRAP_ADMIN_FORCE_PASSWORD_CHANGE=" deploy/.env && sed -i "s|^BOOTSTRAP_ADMIN_FORCE_PASSWORD_CHANGE=.*|BOOTSTRAP_ADMIN_FORCE_PASSWORD_CHANGE=true|" deploy/.env || echo "BOOTSTRAP_ADMIN_FORCE_PASSWORD_CHANGE=true" >> deploy/.env;
    chmod 600 deploy/.env'
  msg_ok "deploy/.env geschrieben (600)."
}

run_lifecycle() {
  pct exec "$CTID" -- bash -c 'set -euo pipefail; cd /opt/synaplan;
    deploy/scripts/prepare.sh;
    # prepare.sh exportiert die Secrets nur in SEINER Shell. Compose braucht sie
    # in DIESER Shell (Host-Env schlaegt --env-file): aus der autoritativen Datei
    # exportieren – gleiche Werte wie validate-release.sh via ensure_deployment_secrets.
    while IFS="=" read -r sk sv || [[ -n "$sk" ]]; do case "$sk" in ""|"#"*) continue;; [A-Z_]* ) export "$sk=$sv";; esac; done < deploy/data/secrets.env;
    docker compose --env-file deploy/.env -f deploy/compose.yaml pull;
    deploy/scripts/validate-release.sh;
    docker compose --env-file deploy/.env -f deploy/compose.yaml up -d;
    deploy/scripts/smoke-test.sh'
  msg_ok "Deploy-Lifecycle (prepare/pull/validate/up/smoke-test) OK."
}

install_systemd() {
  pct exec "$CTID" -- bash -c 'cat > /etc/systemd/system/synaplan.service <<UNIT
[Unit]
Description=Synaplan – AI Control Plane (deploy/compose.yaml)
Documentation=https://github.com/metadist/synaplan
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/synaplan/deploy
ExecStart=/usr/bin/docker compose --env-file .env -f compose.yaml up -d
ExecStop=/usr/bin/docker compose --env-file .env -f compose.yaml stop
ExecReload=/usr/bin/docker compose --env-file .env -f compose.yaml up -d
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable --now synaplan'
  msg_ok "systemd-Unit synaplan enabled + gestartet."
}

# ---------------------------------------------------------------------------
# Verifikation + Final-Box (Task 5)
# ---------------------------------------------------------------------------
verify() {
  pct exec "$CTID" -- systemctl is-active synaplan | grep -q "active" || { msg_error "Service synaplan nicht active."; return 1; }
  msg_ok "Service läuft (systemctl is-active synaplan = active)."
  local i=0
  while [[ $i -lt 120 ]]; do
    if pct exec "$CTID" -- curl -fs http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
      msg_ok "Web UI antwortet (HTTP 200 auf localhost:8000/api/health)."
      return 0
    fi
    sleep 5; i=$((i+1))
  done
  msg_error "Web UI antwortet nicht nach 600 s (Erststart zieht ~4 GB Images)."; return 1
}

print_final() {
  local base="$1"
  cat <<EOF

════════ INSTALLATION ERFOLGREICH ════════
  App       : Synaplan – AI Control Plane
  Container : CT $CTID (Hostname: $HOSTNAME_ARG, onboot=1)
  Ressourcen: $CORES vCPU / $RAM MB RAM / $DISK GB Disk
  Web UI    : $base
  API-Docs  : $base/api/doc
  Admin     : $ADMIN_EMAIL / $ADMIN_PASSWORD (nur jetzt – beim Login ändern!)
  Login     : direkt mit obigem Admin einloggen – keine Registrierung /
               Bestätigungs-Mail nötig (lokal wird ohne SMTP nichts versendet).
  Passwort vergessen? pct exec $CTID -- grep BOOTSTRAP_ADMIN_PASSWORD /opt/synaplan/deploy/.env
  Service   : pct enter $CTID → systemctl status synaplan
  Stack     : pct exec $CTID -- docker compose -f /opt/synaplan/deploy/compose.yaml ps
  Update    : bash synaplan.sh --ctid $CTID (idempotent, pull + restart)
  Deinstall : pct stop $CTID && pct destroy $CTID
  Reboot    : pct reboot $CTID && sleep 90 && curl -fs $base/api/health
  Log       : $LOG_FILE
══════════════════════════════════════════
EOF
}

main() {
  preflight; pick_storage; pick_template; create_ct; get_ct_ip
  setup_lxc; resolve_version
  local base
  base="$(url_base)"
  validate_inputs; write_env "$base"; run_lifecycle; install_systemd; verify; print_final "$base"
  msg_warn "Das Log $LOG_FILE enthält das Admin-Passwort – nach dem Notieren löschen: shred -u \"$LOG_FILE\""
}

main "$@"
