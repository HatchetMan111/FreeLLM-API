#!/usr/bin/env bash
set -euo pipefail
# FreeLLMAPI Proxmox LXC Installer (Community-Scripts-Stil)
# App: FreeLLMAPI (upstream: https://github.com/tashfeenahmed/freellmapi)
# Zweck: Unified /v1-Gateway über 34 Free-LLM-Provider, lokal im LXC, Port 3001
# Einzeiler:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FreeLLM-API/main/install/freellmapi.sh)"

# ---------------- Variablen (oben, Community-Scripts-konform) ----------------
APP="freellmapi"
HOSTNAME="${APP}"
CPU=2
RAM=2048
SWAP=512
DISK=8
TEMPLATE="debian-12-standard"
# STORAGE="auto" erkennt den ersten rootdir-fähigen Storage (z.B. local-lvm/local).
# Override z.B.: STORAGE=local-lvm bash -c "$(...)"  oder  STORAGE=pve-thin ...
STORAGE="${STORAGE:-auto}"
TEMPLATE_STORE="${TEMPLATE_STORE:-local}"
BRIDGE="vmbr0"
PORT=3001
UPSTREAM_REPO="https://github.com/tashfeenahmed/freellmapi.git"
UPSTREAM_BRANCH="main"
OWN_REPO="https://github.com/HatchetMan111/FreeLLM-API.git"
OWN_BRANCH="main"
INSTALL_DIR="/opt/freellmapi"
SRC_DIR="/tmp/freellmapi-install"
LOG="/tmp/freellmapi-install.log"
DEBUG=0
CTID=""

if [ "${DEBUG}" = "1" ]; then
  set -x
fi

# Vollständige Fehlerkette: Stufe, Befehl, Exit-Code, Log-Auszug
fail() {
  local rc=$?
  echo "FAIL: $* (exit=${rc})" >&2
  echo "--- letzte 50 Log-Zeilen (${LOG}) ---" >&2
  tail -n 50 "${LOG}" 2>/dev/null >&2 || true
  echo "Re-Run mit Trace: <Einzeiler> --debug  (entspricht bash -x)" >&2
  return "${rc:-1}"
}

step() {
  local name="$1"
  shift
  echo "### ${name} :: $*" >>"${LOG}" 2>&1
  if "$@" >>"${LOG}" 2>&1; then
    echo "OK: ${name}"
    return 0
  fi
  local rc=$?
  echo "FAIL: Stufe '${name}', Befehl '$*', Exit-Code ${rc}" >&2
  tail -n 50 "${LOG}" >&2 || true
  return "${rc}"
}

preflight() {
  command -v pct >/dev/null 2>&1 || fail "pct fehlt (nur auf PVE-Host als root ausführbar)"
  command -v pvesh >/dev/null 2>&1 || fail "pvesh fehlt"
  command -v pveam >/dev/null 2>&1 || fail "pveam fehlt"
  command -v pvesm >/dev/null 2>&1 || fail "pvesm fehlt"
  [ "$(id -u)" = "0" ] || fail "bitte als root auf dem Proxmox-Host ausführen"
  detect_storage
  detect_template_store
  local tpl
  tpl="$(pveam list "${TEMPLATE_STORE}" 2>/dev/null | grep -o "${TEMPLATE}[^ ]*\\.tar\\.zst" | head -n 1 || true)"
  if [ -z "${tpl}" ]; then
    step "pveam update" pveam update
    # Template-Liste nach Update erneut lesen statt festen Dateinamen zu raten
    tpl="$(pveam available --section system 2>/dev/null | grep -o "${TEMPLATE}[^ ]*\\.tar\\.zst" | head -n 1 || true)"
    [ -n "${tpl}" ] || fail "kein ${TEMPLATE}-Template in 'pveam available --section system' gefunden"
    step "pveam download" pveam download "${TEMPLATE_STORE}" "${tpl}"
  fi
  echo "${TEMPLATE_STORE}:vztmpl/${tpl}" > /tmp/freellmapi.tpl
}

# Root cause Fix: 'local-lxc' existiert nicht auf Standard-PVE (dort local/local-lvm).
# Daher Storage mit rootdir-Content automatisch erkennen statt hart zu kodieren.
detect_storage() {
  local avail
  avail="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' || true)"
  [ -n "${avail}" ] || fail "kein Storage mit Content 'rootdir' gefunden (pvesm status --content rootdir leer). Verfügbare Storages: $(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  if [ "${STORAGE}" != "auto" ]; then
    if echo "${avail}" | grep -qx "${STORAGE}"; then
      echo "Storage: ${STORAGE} (explizit gesetzt, rootdir-fähig)"
      echo "${STORAGE}" > /tmp/freellmapi.storage
      return 0
    fi
    echo "WARN: STORAGE='${STORAGE}' nicht rootdir-fähig oder unbekannt – auto-detect aktiv. Verfügbar: $(echo "${avail}" | tr '\n' ' ')" | tee -a "${LOG}"
  fi
  # Bevorzugt local-lvm (Thin-LVM), dann erster verfügbarer
  if echo "${avail}" | grep -qx "local-lvm"; then
    STORAGE="local-lvm"
  else
    STORAGE="$(echo "${avail}" | head -n 1)"
  fi
  echo "Storage: ${STORAGE} (auto-detect aus: $(echo "${avail}" | tr '\n' ' '))"
  echo "${STORAGE}" > /tmp/freellmapi.storage
}

detect_template_store() {
  local avail
  avail="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' || true)"
  [ -n "${avail}" ] || fail "kein Storage mit Content 'vztmpl' gefunden. Verfügbare Storages: $(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | tr '\n' ' ')"
  if echo "${avail}" | grep -qx "${TEMPLATE_STORE}"; then
    return 0
  fi
  echo "WARN: TEMPLATE_STORE='${TEMPLATE_STORE}' kann keine Templates halten – nutze '$(echo "${avail}" | head -n 1)'." | tee -a "${LOG}"
  TEMPLATE_STORE="$(echo "${avail}" | head -n 1)"
}

fetch_sources() {
  step "Checkout vorbereiten" rm -rf "${SRC_DIR}" || fail "checkout cleanup failed"
  if ! step "Quellen klonen (eigener Installer)" git clone --depth 1 --branch "${OWN_BRANCH}" "${OWN_REPO}" "${SRC_DIR}"; then
    echo "WARN: OWN_REPO nicht klonbar (${OWN_REPO}) – nutze eingebettete Unit als Fallback" | tee -a "${LOG}"
    mkdir -p "${SRC_DIR}/install/systemd"
  fi
  # Falls Unit im Clone fehlt (z.B. Fallback), eingebettete Version schreiben
  if [ ! -f "${SRC_DIR}/install/systemd/freellmapi.service" ]; then
    cat >"${SRC_DIR}/install/systemd/freellmapi.service" <<'EOF'
[Unit]
Description=FreeLLMAPI Unified LLM Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/freellmapi
EnvironmentFile=/opt/freellmapi/.env
ExecStart=/usr/bin/node server/dist/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi
}

existing_ct() {
  pct list | awk 'NR>1 && $4 == "'"${HOSTNAME}"'" {print $1}'
}

next_id() {
  pvesh get /cluster/nextid | tr -d '" '"'"' \n'
}

create_container() {
  local id tmpl storage
  id="$(next_id)"
  tmpl="$(cat /tmp/freellmapi.tpl)"
  storage="$(cat /tmp/freellmapi.storage 2>/dev/null || echo "${STORAGE}")"
  echo "### pct create ${id} rootfs=${storage}:${DISK} tmpl=${tmpl} ###" >>"${LOG}" 2>&1
  # ID-Race: genau 1 RETRY mit frischer ID, dann Abbruch (inkl. pct-Ausgabe im Log)
  if ! pct create "${id}" "${tmpl}" \
    --hostname "${HOSTNAME}" \
    --cores "${CPU}" \
    --memory "${RAM}" \
    --swap "${SWAP}" \
    --rootfs "${storage}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --ostype debian \
    --unprivileged 1 \
    --onboot 1 \
    --start 0 >>"${LOG}" 2>&1; then
    echo "WARN: pct create ${id} fehlgeschlagen – Retry mit frischer ID (siehe Log)" | tee -a "${LOG}"
    tail -n 20 "${LOG}" >&2 || true
    id="$(next_id)"
    pct create "${id}" "${tmpl}" \
      --hostname "${HOSTNAME}" \
      --cores "${CPU}" \
      --memory "${RAM}" \
      --swap "${SWAP}" \
      --rootfs "${storage}:${DISK}" \
      --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
      --ostype debian \
      --unprivileged 1 \
      --onboot 1 \
      --start 0 >>"${LOG}" 2>&1 || fail "pct create failed (nach RETRY, Storage '${storage}' prüfen – 'pvesm status --content rootdir' zeigt gültige Werte)"
  fi
  echo "${id}" > /tmp/freellmapi.ctid
}

wait_for_ip() {
  local id i ip
  id="$(cat /tmp/freellmapi.ctid)"
  i=0
  while [ "${i}" -lt 24 ]; do
    ip="$(pct exec "${id}" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "${ip}" ]; then
      echo "${ip}"
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  fail "keine IP nach 24x5s (Container ${id} bleibt zur Diagnose stehen)"
}

CT_EXEC() { pct exec "$CTID" -- bash -s; }  # liest Heredoc von stdin

setup_base() {
  CT_EXEC <<'EOF'
set -euo pipefail
apt-get update && apt-get install -y curl git openssl ca-certificates sqlite3 build-essential python3
EOF
}

setup_node() {
  CT_EXEC <<'EOF'
set -euo pipefail
if command -v node >/dev/null 2>&1 && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  echo "Node $(node -v) bereits vorhanden"
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
node -v
npm -v
node -e 'const m=Number(process.versions.node.split(".")[0]); if (m < 20 || m >= 25) { console.error("Node-Version ausserhalb 20-24: " + process.versions.node); process.exit(1); }'
EOF
}

setup_repo() {
  CT_EXEC <<EOF
set -euo pipefail
if [ -d ${INSTALL_DIR}/.git ]; then
  git -C ${INSTALL_DIR} fetch origin ${UPSTREAM_BRANCH} --depth 1
  git -C ${INSTALL_DIR} checkout ${UPSTREAM_BRANCH}
  git -C ${INSTALL_DIR} pull --ff-only
else
  rm -rf ${INSTALL_DIR}
  git clone --depth 1 --branch ${UPSTREAM_BRANCH} ${UPSTREAM_REPO} ${INSTALL_DIR}
fi
EOF
}

setup_env() {
  CT_EXEC <<EOF
set -euo pipefail
if [ ! -f ${INSTALL_DIR}/.env ]; then
  KEY="\$(openssl rand -hex 32)"
  printf 'ENCRYPTION_KEY=%s\nPORT=${PORT}\nHOST=::\n' "\$KEY" > ${INSTALL_DIR}/.env
  chmod 600 ${INSTALL_DIR}/.env
  echo "Neue .env mit frischer ENCRYPTION_KEY angelegt"
else
  echo ".env existiert – ENCRYPTION_KEY bleibt erhalten"
  grep -q '^PORT=' ${INSTALL_DIR}/.env || echo 'PORT=${PORT}' >> ${INSTALL_DIR}/.env
  grep -q '^HOST=' ${INSTALL_DIR}/.env || echo 'HOST=::' >> ${INSTALL_DIR}/.env
fi
EOF
}

setup_build() {
  CT_EXEC <<EOF
set -euo pipefail
cd ${INSTALL_DIR}
npm ci
npm run build
test -f server/dist/index.js || { echo "Build-Artefakt server/dist/index.js fehlt"; exit 1; }
EOF
}

setup_units() {
  pct push "$CTID" "$SRC_DIR/install/systemd/freellmapi.service" "/etc/systemd/system/freellmapi.service"
  CT_EXEC <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now freellmapi
EOF
}

setup_firewall() {
  local node
  node=$(hostname)
  pvesh set "/nodes/$node/lxc/$CTID/firewall/options" --enable 1 >>"$LOG" 2>&1 || true
  pvesh create "/nodes/$node/lxc/$CTID/firewall/rules" --action ACCEPT --type in --dport "${PORT}" --proto tcp --comment "freellmapi web ui" >>"$LOG" 2>&1 || true
}

setup_container() {
  step "Basis-Pakete" setup_base
  step "Node.js 22" setup_node
  step "Repo + Upstream-Clone" setup_repo
  step ".env (idempotent)" setup_env
  step "npm ci + build" setup_build
  step "systemd-Unit" setup_units
  step "Firewall" setup_firewall
}

update_container() {
  CTID="$1"
  CT_EXEC <<EOF
set -euo pipefail
git -C ${INSTALL_DIR} fetch origin ${UPSTREAM_BRANCH} --depth 1
git -C ${INSTALL_DIR} checkout ${UPSTREAM_BRANCH}
git -C ${INSTALL_DIR} pull --ff-only
cd ${INSTALL_DIR}
npm ci
npm run build
EOF
  pct push "$CTID" "$SRC_DIR/install/systemd/freellmapi.service" "/etc/systemd/system/freellmapi.service"
  CT_EXEC <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now freellmapi
systemctl restart freellmapi
EOF
  verify
}

verify() {
  pct exec "$CTID" -- systemctl is-active freellmapi || fail "service freellmapi inaktiv (journalctl: pct exec $CTID -- journalctl -u freellmapi -n 100)"
  # /api/ping ist Upstream-Healthcheck (docker-compose.yml); Fallbacks für künftige Versionen
  if ! pct exec "$CTID" -- bash -c 'curl -fsS http://127.0.0.1:3001/api/ping'; then
    pct exec "$CTID" -- bash -c 'curl -fsS http://127.0.0.1:3001/ >/dev/null' || fail "verify localhost:3001 fail (weder /api/ping noch / erreichbar)"
  fi
  pct config "$CTID" | grep -qi onboot || fail "onboot nicht gesetzt"
  local ip
  ip="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
  [ -n "${ip}" ] || fail "keine CT-IP ermittelbar"
  curl -fs "http://${ip}:${PORT}/" >/dev/null || fail "host-seitiger ${PORT}-Check auf ${ip} fail"
  echo "FERTIG: http://${ip}:${PORT} (CT ${CTID}, Hostname ${HOSTNAME})"
}

main() {
  if [ "${1:-}" = "--debug" ]; then
    DEBUG="1"
    set -x
  fi
  : > "${LOG}" || true
  local existing
  preflight
  fetch_sources
  existing="$(existing_ct || true)"
  if [ -n "${existing}" ]; then
    echo "CT '${HOSTNAME}' existiert (ID ${existing}) – Update-Pfad, kein neuer Container."
    update_container "${existing}"
    return 0
  fi
  create_container
  CTID="$(cat /tmp/freellmapi.ctid)"
  pct start "$CTID"
  wait_for_ip
  setup_container
  verify
  # Deinstall: pct stop <ctid> && pct destroy <ctid> (CT bleibt bei FAIL zur Diagnose stehen)
}

main "$@"
