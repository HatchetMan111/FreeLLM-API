# FreeLLMAPI auf Proxmox LXC – Einzeiler-Installation

FreeLLMAPI (`https://github.com/tashfeenahmed/freellmapi`) ist ein Unified-LLM-Gateway:
7,4 Mrd. Tokens/Monat, 34 Free-Provider, 635 Modell-Endpunkte hinter einem
OpenAI-kompatiblen `/v1`-Endpoint, mit Smart-Routing, Failover und verschlüsselten Keys.
Läuft hier **vollständig lokal** in einem unprivilegierten LXC, **nativ**
(Node 22 LTS, kein Docker): Dashboard + API auf Port **3001** als systemd-Service
mit `Restart=always`, Container mit `onboot: 1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `freellmapi` |
| Zweck | Unified Free-LLM-Gateway (`/v1` OpenAI-kompatibel, Keys/Chain im Dashboard) |
| Tech-Stack | Node.js 22 / TypeScript + React (Vite-Build), SQLite (`server/data`), nativ ohne Docker |
| GitHub-Repo (Upstream App) | `https://github.com/tashfeenahmed/freellmapi` |
| GitHub-Repo (dieser Installer) | `https://github.com/HatchetMan111/FreeLLM-API` (eingetragen) |
| Web UI | `http://<LXC-IP>:3001` (bind `::`, also 0.0.0.0-kompatibel) |
| Health | `http://<LXC-IP>:3001/api/ping` |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 512 MB Swap / 8 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`, 1 Retry bei Race) |
| Storage | **auto-detect**: erster `rootdir`-Storage (`pvesm status --content rootdir`, bevorzugt `local-lvm`). Override: `STORAGE=local bash -c "$(...)"` |
| Template | `debian-12-standard` (wird geladen falls fehlend) |

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Direkt auf dem Proxmox-Host als root:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeLLM-API/main/install/freellmapi.sh)"
```

Nur `--debug` wird unterstützt (`= bash -x`, maximale Fehlermeldungskette):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeLLM-API/main/install/freellmapi.sh)" --debug
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools (root, `pct`/`pvesh`/`pveam`), lädt das
   `debian-12-standard`-Template falls nötig,
2. sucht per Hostname (`freellmapi`): existiert → Update-Pfad
   (`git pull` + `npm ci` + `npm run build` + Unit neu pushen + restart).
   Sonst: nächste freie CT-ID, erstellt den LXC (`onboot: 1`, unprivilegiert, DHCP),
3. installiert im Container Node 22, klont Upstream nach `/opt/freellmapi`,
   legt `/opt/freellmapi/.env` mit frischer `ENCRYPTION_KEY` an (bleibt bei Re-Run erhalten),
   baut (`npm ci && npm run build`), legt die systemd-Unit an (`systemctl enable --now`),
   öffnet die Firewall für 3001,
4. verifiziert `systemctl is-active` + HTTP-Checks auf `localhost:3001`
   (`/api/ping`, Fallback `/`) + Host-Check auf die CT-IP und gibt die finale URL aus.

Erwartete Schlussausgabe (Beispiel):

```text
OK: Basis-Pakete
OK: Node.js 22
OK: Repo + Upstream-Clone
OK: .env (idempotent)
OK: Admin-Account (deklarativ)
OK: npm ci + build
OK: systemd-Unit
OK: Firewall
FERTIG: http://192.168.1.100:3001 (CT 100, Hostname freellmapi)
Login: admin@freellmapi.local / <generiertes-passwort>
Hinweis: Passwort im Dashboard unter Settings ändern. Vergessen? Auf dem Host: pct exec 100 -- cat /opt/freellmapi/freellmapi.config.json
```

Danach: `http://<LXC-IP>:3001` öffnen und direkt mit obigen Daten einloggen –
**kein Setup-Code nötig**: Der Installer legt den ersten Account deklarativ
(`FREEAPI_CONFIG_PATH`, Upstream-Feature) vor dem ersten Start an, dadurch wird
gar kein `First-run setup code` erzeugt. Eigene Mailadresse? Vorab:
`ADMIN_EMAIL=du@beispiel.de bash -c "$(...)"`.

Dann auf **Keys** Provider-Keys eintragen,
**Fallback Chain** sortieren, Unified-Key aus dem Keys-Header kopieren und
OpenAI-Clients auf `http://<LXC-IP>:3001/v1` zeigen lassen.

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active freellmapi   # muss: active
curl -fs http://$(pct exec $CT -- hostname -I | awk '{print $1}'):3001/api/ping && echo UI-OK
pct config $CT | grep -i onboot                  # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeLLM-API/main/install/freellmapi.sh)"
# Hostname existiert -> Update-Pfad: git pull + npm ci/build + Unit neu pushen + restart. Kein neuer CT.
```

Manuell im Container:

```bash
pct enter 100
cd /opt/freellmapi && git pull --ff-only
npm ci && npm run build
systemctl restart freellmapi && systemctl status freellmapi --no-pager --full
curl -fs http://127.0.0.1:3001/api/ping && echo PING-OK
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/freellmapi-install.log`.
- Bei Fehlern druckt das Skript: Stufe, Befehl, Exit-Code, die letzten 50
  Log-Zeilen — niemals nur die letzte Zeile. Re-run mit Trace (`--debug`).
- Im Container weiter eingrenzen:

```bash
pct exec 100 -- systemctl status freellmapi --no-pager --full
pct exec 100 -- journalctl -u freellmapi --no-pager -n 100
pct exec 100 -- node -v
pct exec 100 -- curl -v http://127.0.0.1:3001/api/ping
tail -n 200 /tmp/freellmapi-install.log   # auf dem Host
```

## 6. Dateien in diesem Repo

```text
FreeLLM-API/
├── install/freellmapi.sh               # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── install/systemd/freellmapi.service  # Unit (Restart=always, After=network-online.target)
└── README.md                           # diese Datei
```

## 7. Hinweise

- **Nativ statt Docker:** Der Installer nutzt bewusst kein Docker im LXC.
  Node läuft direkt in `/opt/freellmapi`, DB unter `server/data/freeapi.db`
  (Upstream-Default, ggf. `FREEAPI_DB_PATH` in `.env` setzen).
- **DHCP-Hinweis:** Ändert sich die Container-IP, Installer erneut laufen
  lassen (Update-Pfad verifiziert neu). Für stabile URLs DHCP-Reservierung einrichten.
- **LXC statt VM:** Kein GPU/Kernel-Bedarf, ~40 MB RSS idle — unprivilegierter LXC reicht.
  Erst bei Sonderkernen (z.B. eigene Kernel-Module) auf VM wechseln.
- **Erst-Setup:** Der erste Dashboard-Account wird über die Web UI angelegt;
  bei LAN-Exposure (`HOST=::` ist offen) sofort Passwort setzen.
