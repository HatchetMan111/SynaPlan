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
