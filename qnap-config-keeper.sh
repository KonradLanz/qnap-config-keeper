#!/bin/sh
# =============================================================================
# qnap-config-keeper.sh
# etckeeper-Äquivalent für QNAP QTS (busybox ash + Entware)
#
# Trackt:
#   /etc/config/          (Netzwerk, User, Dienste, autorun.sh, smb.conf ...)
#   /etc/crontabs/root
#   QPKG-Liste            (qpkg_cli --list Snapshot)
#   Optional: docker-compose.yml + .env (konfigurierbar)
#
# Nutzung:
#   qnap-config-keeper.sh init            -- Git-Repo anlegen
#   qnap-config-keeper.sh snap            -- Snapshot + Commit falls Änderung
#   qnap-config-keeper.sh status          -- letzter Commit, Diff-Vorschau
#   qnap-config-keeper.sh install         -- Cron + autorun.sh einrichten
#   qnap-config-keeper.sh restore FILE    -- einzelne Datei wiederherstellen
#
# Philosophie: etckeeper-Style
#   - Alles tracken außer shadow/passwd und binäre Noise-Dateien
#   - Repo lokal auf SSD, nie nach GitHub pushen
#   - chmod 700 auf Repo-Verzeichnis schützt sensitive Daten
#   - Permissions werden nicht verändert (QNAP stellt sie)
#
# Kompatibel mit: busybox ash (QNAP QTS)
# Requires: git (opkg install git)
#
# License: AGPLv3 - https://www.gnu.org/licenses/agpl-3.0.html
# Copyright (c) 2026 GrEEV.com KG
# =============================================================================

# ── Konfiguration ─────────────────────────────────────────────────────────────
REPO_DIR="/share/CACHEDEV2_DATA/config-keeper"
BRANCH="main"
GIT_USER="qnap-config-keeper"
GIT_EMAIL="config-keeper@localhost"

# Tier-2 Log auf SSD (WARN/CRIT), Tier-1 auf tmpfs
LOG_TMPFS="/tmp/config-keeper.log"
LOG_SSD="${REPO_DIR}/config-keeper.log"

# Zu trackende Pfade
TRACK_CONFIG="/etc/config"
TRACK_CRONTAB="/etc/crontabs/root"

# Optionale docker-compose Pfade (leer lassen = nicht tracken)
# Format: leerzeichen-getrennte Verzeichnisse
DOCKER_COMPOSE_PATHS=""
# Beispiel:
# DOCKER_COMPOSE_PATHS="/share/CACHEDEV2_DATA/paperless-ngx"

# git-Pfad (Entware zuerst, dann System)
GIT="$(command -v git 2>/dev/null || echo /opt/bin/git)"

# ── Farben (nur bei echtem TTY) ───────────────────────────────────────────────
if [ -t 1 ]; then
  R='\033[0m'
  COK='\033[0;32m'
  CWN='\033[0;33m'
  CFI='\033[0;31m'
  CIN='\033[0;36m'
  CBL='\033[1m'
else
  R=''; COK=''; CWN=''; CFI=''; CIN=''; CBL=''
fi

# ── Logging: Zwei-Tier-Strategie ──────────────────────────────────────────────
# Tier-1: alles nach /tmp (tmpfs, flüchtig, kein HDD-Touch)
# Tier-2: nur WARN/CRIT nach SSD-Log (persistent)

log_raw() {
  LEVEL="$1"; shift
  TS="$(date '+%Y-%m-%d %H:%M:%S')"
  MSG="[$TS] [$LEVEL] $*"
  # Tier-1: immer
  echo "$MSG" >> "$LOG_TMPFS" 2>/dev/null
  # Tier-2: nur WARN und CRIT
  case "$LEVEL" in
    WARN|CRIT)
      [ -d "$(dirname "$LOG_SSD")" ] && echo "$MSG" >> "$LOG_SSD" 2>/dev/null
      ;;
  esac
}

info() { log_raw "INFO" "$*"; printf "${CIN}[INFO]${R} %s\n" "$*"; }
ok()   { log_raw "INFO" "$*"; printf "${COK}[ OK ]${R} %s\n" "$*"; }
warn() { log_raw "WARN" "$*"; printf "${CWN}[WARN]${R} %s\n" "$*"; }
crit() { log_raw "CRIT" "$*"; printf "${CFI}[CRIT]${R} %s\n" "$*"; }
die()  { crit "$*"; exit 1; }
hr()   { printf '%s\n' '──────────────────────────────────────────────────'; }
say()  { printf "${CBL}%s${R}\n" "$*"; }

# ── Hilfsfunktion: md-RAID-bewusste Rotational-Erkennung ─────────────────────
# Übernommen aus qnap-storage-advisor (bewährtes Pattern)
# Gibt 0 (SSD) oder 1 (HDD) zurück für einen beliebigen Pfad
path_is_rotational() {
  TARGET="$1"
  REALDEV=$(df "$TARGET" 2>/dev/null | tail -1 | awk '{print $1}')
  case "$REALDEV" in
    /dev/*) ;;
    *) echo "unknown"; return ;;
  esac
  DEVNAME=$(basename "$REALDEV")
  if [ -f "/sys/block/$DEVNAME/queue/rotational" ]; then
    cat "/sys/block/$DEVNAME/queue/rotational"
    return
  fi
  MDBASE=$(echo "$DEVNAME" | sed 's/p[0-9]*$//' | grep '^md')
  if [ -n "$MDBASE" ] && [ -d "/sys/block/$MDBASE/slaves" ]; then
    for slave in /sys/block/$MDBASE/slaves/*; do
      [ -e "$slave" ] || continue
      SLAVE_BASE=$(basename "$slave" | sed 's/[0-9]*$//')
      if [ -f "/sys/block/$SLAVE_BASE/queue/rotational" ]; then
        ROT=$(cat "/sys/block/$SLAVE_BASE/queue/rotational")
        [ "$ROT" = "1" ] && { echo "1"; return; }
      fi
    done
    echo "0"; return
  fi
  echo "unknown"
}

# ── Voraussetzungen prüfen ────────────────────────────────────────────────────
require_git() {
  "$GIT" --version >/dev/null 2>&1 || \
    die "git nicht gefunden. Bitte: opkg install git"
}

require_repo() {
  [ -d "$REPO_DIR/.git" ] || \
    die "Repo nicht initialisiert. Zuerst: $0 init"
}

# ── Snapshots erstellen ───────────────────────────────────────────────────────
snapshot_config() {
  DST="$REPO_DIR/snapshot/etc/config"
  if [ -d "$TRACK_CONFIG" ]; then
    mkdir -p "$DST"
    cp -r "$TRACK_CONFIG/" "$DST/" 2>/dev/null
  else
    warn "$TRACK_CONFIG nicht gefunden, übersprungen."
  fi
}

snapshot_crontab() {
  DST="$REPO_DIR/snapshot/etc/crontabs"
  if [ -f "$TRACK_CRONTAB" ]; then
    mkdir -p "$DST"
    cp "$TRACK_CRONTAB" "$DST/root" 2>/dev/null
  else
    warn "$TRACK_CRONTAB nicht gefunden, übersprungen."
  fi
}

snapshot_qpkg() {
  DST="$REPO_DIR/snapshot/qpkg-list.txt"
  {
    echo "# QPKG-Liste - generiert von qnap-config-keeper"
    echo "# $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    if command -v qpkg_cli >/dev/null 2>&1; then
      qpkg_cli --list 2>/dev/null
    elif [ -f /etc/config/qpkg.conf ]; then
      grep '\[' /etc/config/qpkg.conf | tr -d '[]'
    else
      echo "# qpkg_cli nicht verfügbar"
    fi
  } > "$DST"
}

snapshot_docker_compose() {
  [ -z "$DOCKER_COMPOSE_PATHS" ] && return
  for dir in $DOCKER_COMPOSE_PATHS; do
    DST="$REPO_DIR/snapshot/docker-compose/$(basename "$dir")"
    mkdir -p "$DST"
    for f in docker-compose.yml docker-compose.yaml .env; do
      [ -f "$dir/$f" ] && cp "$dir/$f" "$DST/$f" 2>/dev/null
    done
  done
}

do_snapshot() {
  snapshot_config
  snapshot_crontab
  snapshot_qpkg
  snapshot_docker_compose
}

# ── .gitignore schreiben ──────────────────────────────────────────────────────
write_gitignore() {
  cat > "$REPO_DIR/.gitignore" << 'EOF'
# =============================================================
# etckeeper-Style: nur shadow/passwd und Binär-Noise ausschließen
# Repo bleibt lokal (chmod 700), nie nach GitHub pushen
# =============================================================

# Passwort-Hashes (etckeeper-Standard)
snapshot/etc/config/shadow
snapshot/etc/config/shadow-
snapshot/etc/config/passwd

# MySQL/MariaDB Binärdaten (kein Diff-Wert, groß)
snapshot/etc/config/nc/db/
snapshot/etc/config/qulog/db/

# LVM Metadaten (groß, auto-generiert)
snapshot/etc/config/lvm/archive/
snapshot/etc/config/lvm/backup/

# Lizenz-Entschlüsselung (QNAP-intern)
snapshot/etc/config/qlicense/decrypt/

# Signing-Datenbanken (binär)
snapshot/etc/config/anti_tamper.db
snapshot/etc/config/nas_priv2.db
snapshot/etc/config/nas_sign_qpkg.db
snapshot/etc/config/nas_sign_fw.db

# News/RSS (kein Config-Wert)
snapshot/etc/config/rssdoc/
snapshot/etc/config/.app_news/
snapshot/etc/config/SecurityCenter/.@analytic/

# Script-interne Logs und Temp-Dateien
*.swp
*.tmp
*~
EOF
}

# ── CMD: init ────────────────────────────────────────────────────────────────
cmd_init() {
  require_git
  say "Config-Keeper: init"
  hr

  # SSD-Check: warnen wenn REPO_DIR auf HDD liegt
  if [ -d "$REPO_DIR" ] || mkdir -p "$REPO_DIR" 2>/dev/null; then
    ROT=$(path_is_rotational "$REPO_DIR")
    case "$ROT" in
      0) ok  "REPO_DIR liegt auf SSD/NVMe: $REPO_DIR" ;;
      1) warn "REPO_DIR liegt auf HDD -- verhindert HDD-Sleep! Empfohlen: CACHEDEV2_DATA (SSD)" ;;
      *) info "Storage-Typ für REPO_DIR konnte nicht ermittelt werden" ;;
    esac
  fi

  cd "$REPO_DIR"

  if [ -d ".git" ]; then
    info "Repo existiert bereits, überspringe git init."
  else
    "$GIT" init -b "$BRANCH" 2>/dev/null || "$GIT" init
    "$GIT" config user.name  "$GIT_USER"
    "$GIT" config user.email "$GIT_EMAIL"
    ok "Git-Repo initialisiert."
  fi

  # Repo absichern: nur root darf zugreifen
  chmod 700 "$REPO_DIR"
  chmod 700 "$REPO_DIR/.git" 2>/dev/null || true
  ok "chmod 700 auf $REPO_DIR gesetzt."

  write_gitignore
  ok ".gitignore geschrieben."

  # Erster Snapshot + Commit
  mkdir -p "$REPO_DIR/snapshot"
  do_snapshot

  "$GIT" add -A
  if "$GIT" diff --cached --quiet; then
    info "Keine Dateien im Snapshot — Repo ist leer."
  else
    "$GIT" commit -m "init: erster Snapshot $(date '+%Y-%m-%d %H:%M:%S')"
    ok "Initialer Commit erstellt."
  fi

  hr
  say "Init abgeschlossen. Nächste Schritte:"
  info "  $0 snap       -- manueller Snapshot"
  info "  $0 install    -- Cron einrichten (4x täglich)"
  info "  $0 status     -- aktuellen Stand anzeigen"
}

# ── CMD: snap ────────────────────────────────────────────────────────────────
cmd_snap() {
  require_git
  require_repo
  cd "$REPO_DIR"

  info "Erstelle Snapshot ..."
  do_snapshot

  "$GIT" add -A

  if "$GIT" diff --cached --quiet; then
    ok "Keine Änderungen seit letztem Commit."
  else
    CHANGED=$("$GIT" diff --cached --name-only | head -20 | tr '\n' ' ')
    "$GIT" commit -m "snap: $(date '+%Y-%m-%d %H:%M:%S') | ${CHANGED}"
    ok "Committed: ${CHANGED}"
  fi
}

# ── CMD: status ───────────────────────────────────────────────────────────────
cmd_status() {
  require_git
  require_repo
  cd "$REPO_DIR"

  say "Config-Keeper: status"
  hr

  say "Letzter Commit:"
  "$GIT" log --oneline -1
  printf '\n'

  say "Letzte 5 Commits:"
  "$GIT" log --oneline -5
  printf '\n'

  # Diff-Vorschau ohne zu committen
  say "Änderungen seit letztem Commit (Vorschau):"
  do_snapshot
  "$GIT" add -A
  if "$GIT" diff --cached --quiet; then
    ok "Keine Änderungen."
  else
    "$GIT" diff --cached --stat
    printf '\n'
    info "Tipp: '$0 snap' um Änderungen zu committen."
  fi
  # Staged Änderungen wieder zurücksetzen (nur Vorschau)
  "$GIT" reset HEAD >/dev/null 2>&1 || true
  printf '\n'

  say "Log-Tail (Tier-1 tmpfs):"
  if [ -f "$LOG_TMPFS" ]; then
    tail -10 "$LOG_TMPFS"
  else
    info "Noch kein Log vorhanden."
  fi
  hr
}

# ── CMD: install ──────────────────────────────────────────────────────────────
cmd_install() {
  require_repo

  SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  CRONTAB_FILE="/etc/config/crontab"
  AUTORUN="/etc/config/autorun.sh"

  say "Config-Keeper: install"
  hr

  # ── Cron einrichten (4x täglich: 6, 12, 18, 23 Uhr) ──────────────────────
  if grep -q "qnap-config-keeper" "$CRONTAB_FILE" 2>/dev/null; then
    info "Cron-Job existiert bereits:"
    grep "qnap-config-keeper" "$CRONTAB_FILE"
  else
    CRON_LINE="0 6,12,18,23 * * *  $SCRIPT_PATH snap >> $LOG_TMPFS 2>&1  # qnap-config-keeper"
    echo "$CRON_LINE" >> "$CRONTAB_FILE"
    # Cron neu laden (QNAP-Weg)
    crontab "$CRONTAB_FILE" 2>/dev/null && ok "Cron neu geladen." || \
      warn "Crontab-Reload fehlgeschlagen — bitte manuell: crontab $CRONTAB_FILE"
    ok "Cron-Job eingetragen: $CRON_LINE"
  fi

  # ── autorun.sh einrichten ─────────────────────────────────────────────────
  if grep -q "qnap-config-keeper" "$AUTORUN" 2>/dev/null; then
    info "autorun.sh Eintrag existiert bereits."
  else
    # autorun.sh anlegen falls nicht vorhanden
    if [ ! -f "$AUTORUN" ]; then
      echo '#!/bin/sh' > "$AUTORUN"
      chmod +x "$AUTORUN"
    fi
    # Nach Boot einmaligen snap ausführen (verzögert, bis Dienste bereit)
    AUTORUN_LINE="( sleep 60 && $SCRIPT_PATH snap ) &  # qnap-config-keeper"
    echo "$AUTORUN_LINE" >> "$AUTORUN"
    ok "autorun.sh Eintrag hinzugefügt: nach Boot snap mit 60s Verzögerung."
  fi

  hr
  say "Installation abgeschlossen."
  info "Snap läuft täglich um: 6:00, 12:00, 18:00, 23:00"
  info "Außerdem: einmal nach jedem NAS-Neustart (60s Verzögerung)"
  info "Manueller Snap jederzeit: $0 snap"
}

# ── CMD: restore ─────────────────────────────────────────────────────────────
cmd_restore() {
  require_git
  require_repo

  TARGET="${1:-}"
  [ -z "$TARGET" ] && die "Nutzung: $0 restore <Pfad>  (z.B. /etc/config/smb.conf)"

  # Pfad im Snapshot ermitteln
  SNAP_PATH="$REPO_DIR/snapshot${TARGET}"

  if [ ! -f "$SNAP_PATH" ]; then
    die "Datei nicht im Snapshot gefunden: $SNAP_PATH"
  fi

  say "Config-Keeper: restore"
  hr
  info "Quelle : $SNAP_PATH"
  info "Ziel   : $TARGET"
  printf '\n'

  # Diff anzeigen vor Restore
  if [ -f "$TARGET" ]; then
    say "Unterschiede (aktuell vs. Snapshot):"
    diff "$TARGET" "$SNAP_PATH" || true
    printf '\n'
  fi

  # Bestätigung (interaktiv)
  if [ -t 0 ]; then
    printf "Datei wirklich wiederherstellen? [j/N] "
    read -r ANS
    case "$ANS" in
      j|J|y|Y) ;;
      *) info "Abgebrochen."; exit 0 ;;
    esac
  fi

  # Zielverzeichnis sicherstellen
  mkdir -p "$(dirname "$TARGET")"
  cp "$SNAP_PATH" "$TARGET"
  ok "Wiederhergestellt: $TARGET"
  info "Hinweis: Dienst ggf. neu starten damit Änderung wirksam wird."
}

# ── Einstiegspunkt ────────────────────────────────────────────────────────────
CMD="${1:-}"
[ $# -gt 0 ] && shift

case "$CMD" in
  init)    cmd_init    ;;
  snap)    cmd_snap    ;;
  status)  cmd_status  ;;
  install) cmd_install ;;
  restore) cmd_restore "${1:-}" ;;
  *)
    printf '%s\n' \
      "Nutzung: $(basename "$0") <Befehl> [Optionen]" \
      "" \
      "Befehle:" \
      "  init              Git-Repo anlegen & ersten Snapshot committen" \
      "  snap              Snapshot erstellen, Commit falls Änderung" \
      "  status            Letzter Commit, Diff-Vorschau, Log-Tail" \
      "  install           Cron (4x täglich) + autorun.sh einrichten" \
      "  restore FILE      Einzelne Datei aus Git wiederherstellen" \
      "" \
      "Repo   : $REPO_DIR" \
      "Log    : $LOG_TMPFS (Tier-1 tmpfs)" \
      "       : $LOG_SSD (Tier-2 SSD, nur WARN/CRIT)"
    exit 1
    ;;
esac
