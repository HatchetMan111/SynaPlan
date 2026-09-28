# Synaplan auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Synaplan-App-Repository.**
> Dieses Repo enthält **nur den Proxmox-LXC-Installer** für Synaplan — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/metadist/synaplan`. Das Install-Script nutzt deren
> offiziellen `deploy/`-Production-Contract (`deploy/compose.yaml` +
> `deploy/scripts/{prepare,validate-release,smoke-test}`) mit dem
> published Image `ghcr.io/metadist/synaplan` — alles läuft vollständig lokal.

Synaplan (Open-Source AI-Control-Plane: Chat, Knowledge/RAG, Media, Agents,
DAG-Routing, Plugins) läuft in einem unprivilegierten LXC-Container mit
Docker Compose im **Server-Mode (Prod)**: Web UI auf Port **8000**,
systemd-Service mit `enable`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `synaplan` |
| Zweck | AI-Control-Plane (Chat, Wissen, Medien, Agenten, DAG-Routing, Plugins) |
| Tech-Stack | FrankenPHP/Symfony + Vue (Docker) + MariaDB + Redis + Centrifugo + Tika + Qdrant + TTS |
| Upstream-Repo | `https://github.com/metadist/synaplan` |
| Web UI | `http://<LXC-IP>:8000`, API-Docs `http://<LXC-IP>:8000/api/doc`, bind `0.0.0.0` via `SYNAPLAN_HTTP_BIND` |
| Standard-Ressourcen | 4 vCPU / 8192 MB RAM / 30 GB Disk (Upstream-Minimum 8 GB RAM — mit weniger droht OOM) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | `nesting=1,keyctl=1` (Docker-Voraussetzung), unprivilegiert |
| Erst-Admin (Default) | `admin@synaplan.local` — Passwort wird **nur in der Final-Box** angezeigt, beim ersten Login ändern |

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SynaPlan/main/install/synaplan.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=4 RAM=8192 DISK=30 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SynaPlan/main/install/synaplan.sh)"
bash synaplan.sh --ctid 101 --cores 4 --memory 8192 --disk 30 --bridge vmbr0 --storage local-lvm
bash synaplan.sh --ctid 100 --admin-email ich@domain.tld --admin-password 'Geheim-123'
bash synaplan.sh --ctid 100 --version 1.2.3 --domain https://ai.example.com
bash synaplan.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `synaplan` (`onboot: 1`, unprivilegiert, `nesting=1,keyctl=1`),
3. installiert im Container Docker + Compose-Plugin, klont Upstream shallow nach
   `/opt/synaplan`, schreibt `deploy/.env` (Mode 600, `APP_URL=http://<IP>:8000`,
   `SYNAPLAN_HTTP_BIND=0.0.0.0`, Version vom neuesten GitHub-Release,
   Zufalls-Adminpasswort), fährt `prepare → pull → validate → up -d → smoke-test`,
   schreibt die systemd-Unit, `systemctl enable --now synaplan`,
4. verifiziert `systemctl is-active synaplan` + HTTP auf `127.0.0.1:8000/api/health`
   (bis 600 s, Erststart zieht ~4 GB) und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active synaplan = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8000/api/health).

════════ INSTALLATION ERFOLGREICH ════════
  App       : Synaplan – AI Control Plane
  Container : CT 100 (Hostname: synaplan, onboot=1)
  Ressourcen: 4 vCPU / 8192 MB RAM / 30 GB Disk
  Web UI    : http://192.168.1.100:8000
  API-Docs  : http://192.168.1.100:8000/api/doc
  Admin     : admin@synaplan.local / aB3... (nur jetzt – beim Login ändern!)
  Login     : direkt mit obigem Admin einloggen – keine Registrierung /
               Bestätigungs-Mail nötig (lokal wird ohne SMTP nichts versendet).
  Passwort vergessen? pct exec 100 -- grep BOOTSTRAP_ADMIN_PASSWORD /opt/synaplan/deploy/.env
  Service   : pct enter 100 → systemctl status synaplan
  Stack     : pct exec 100 -- docker compose -f /opt/synaplan/deploy/compose.yaml ps
  Update    : bash synaplan.sh --ctid 100 (idempotent, pull + restart)
  Deinstall : pct stop 100 && pct destroy 100
  Reboot    : pct reboot 100 && sleep 90 && curl -fs http://192.168.1.100:8000/api/health
  Log       : /tmp/synaplan-install-2026-....log
══════════════════════════════════════════
```

Danach im Browser `http://<LXC-IP>:8000` öffnen, mit `admin@synaplan.local`
einloggen (Passwort ändern), unter **Operate → AI infrastructure → Models & keys**
einen Provider-Key hinterlegen (kostenlos z. B. Groq) — fertig.

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 90   # Erster Start nach Reboot: Docker + 8 Dienste brauchen ~60–90 s
pct exec $CT -- systemctl is-active synaplan   # muss: active
pct exec $CT -- docker ps --format '{{.Names}} {{.Status}}'
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):8000/api/health && echo WEBUI-OK
pct config $CT | grep -i onboot              # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash synaplan.sh --ctid 100
# erkennt CT + /opt/synaplan, behält Secrets/DB, aktualisiert IP/Version,
# danach compose pull + up -d + smoke-test + restart.
```

Manuell im Container:

```bash
pct enter 100
cd /opt/synaplan && git pull --ff-only
cd deploy && docker compose --env-file .env -f compose.yaml pull && docker compose --env-file .env -f compose.yaml up -d
systemctl restart synaplan 2>/dev/null; ../deploy/scripts/smoke-test.sh
curl -fs http://127.0.0.1:8000/api/health && echo WEBUI-OK
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/synaplan-install-<Datum>.log` (enthält auch das angezeigte Admin-Passwort — nach dem Notieren löschen: `shred -u /tmp/synaplan-install-*.log`).
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl -u synaplan -n 100`,
  `systemctl status synaplan`, `docker ps -a`, `compose logs --tail=100` —
  niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x synaplan.sh --ctid 100
DEBUG=1 bash synaplan.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/synaplan-install-*.log
pct exec 100 -- journalctl -u synaplan --no-pager -n 100
pct exec 100 -- docker compose -f /opt/synaplan/deploy/compose.yaml logs --tail=100 --no-color
```

## 6. Dateien in diesem Paket

```text
SynaPlan/                        # dieses Repo: NUR Proxmox-Installer, kein App-Code
├── install/synaplan.sh          # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/synaplan.service     # systemd-Unit (oneshot + enable, After=network-online.target + docker.service)
└── README.md                    # diese Datei
```

`install/synaplan.sh` ist einzeiler-fähig (bettet alles ein, keine weiteren
Dateien nötig). `systemd/synaplan.service` liegt zusätzlich als Referenz bei.

## 7. Hinweise

- **Warum Server-Mode statt Try/Dev-Stack?** Der Dev-Stack (`make up`) baut das
  Backend-Image lokal + `npm ci` (5–15 Min Erststart, mehr RAM) und ist nicht für
  Dauerbetrieb gedacht. `deploy/compose.yaml` nutzt das published Image und die
  dokumentierten Lifecycle-Scripts — schneller und stabiler im LXC.
- **Warum 8 GB / 30 GB?** Backend + Worker + Scheduler + MariaDB + Redis +
  Centrifugo + Tika + Qdrant + TTS brauchen real ~6–8 GB RAM und ~4 GB Images.
  Mit 2 GB/8 GB droht OOM bzw. volle Disk — darum warnt das Skript unter
  6 GB RAM / 20 GB Disk.
- **Bind 0.0.0.0:** Upstream bindet per Default an `127.0.0.1:8000` (nur lokal im
  LXC). Der Installer setzt `SYNAPLAN_HTTP_BIND=0.0.0.0`, sonst wäre die Web UI
  aus dem LAN nicht erreichbar.
- **Secrets:** `deploy/.env` (Mode 600) + `deploy/data/secrets.env` (generiert von
  `prepare.sh`). **Beides sichern** — eine DB ohne `secrets.env` lässt sich nicht
  öffnen. Re-Runs fassen bestehende Secrets nie an.
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen lassen —
  er erkennt die neue IP und schreibt `APP_URL`/`FRONTEND_URL` neu (Secrets bleiben).
  Für stabile URLs DHCP-Reservierung oder statische IP einrichten.
- **Kein Local-AI Default:** Profile `local-ai` (Ollama, +1 GB, optional
  `gpt-oss:20b` +14 GB) und `office` (Collabora, +2 GB RAM) bleiben aus.
  Chat braucht daher einen Provider-Key (Groq kostenlos) — oder `local-ai`
  manuell im Container aktivieren.
- Erster Start zieht ~4 GB Images — Web UI kann 5–10 Minuten brauchen
  (Health wird bis zu 600 s gepollt).
- **Login:** Default `admin@synaplan.local`, Passwort nur in der Final-Box
  (wird nirgends geloggt, nur die Länge). Beim ersten Login ändern
  (`BOOTSTRAP_ADMIN_FORCE_PASSWORD_CHANGE=true`).
