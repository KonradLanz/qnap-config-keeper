#!/bin/sh
# =============================================================================
# qnap-config-keeper.sh
# etckeeper-equivalent for QNAP QTS (busybox ash + Entware)
#
# Trackt:
#   /etc/config/          (Netzwerk, User, Dienste, autorun.sh)
#   /etc/crontabs/root
#   QPKG-Liste (qpkg.conf snapshot)
#
# Nutzung:
#   qnap-config-keeper.sh init        -- Git-Repo initialisieren
#   qnap-config-keeper.sh commit       -- Sofort-Commit (manuell)
#   qnap-config-keeper.sh watch        -- Dauerhaft per inotifywait überwachen
#   qnap-config-keeper.sh install-cron -- Cron-Job einrichten (stündlich)
#   qnap-config-keeper.sh status       -- git status anzeigen
#   qnap-config-keeper.sh log          -- git log (kurz) anzeigen
#   qnap-config-keeper.sh diff         -- git diff (unstaged) anzeigen
# =============================================================================

set -e

# ---------------------------------------------------------------------------
# Konfiguration (anpassen nach Bedarf)
# ---------------------------------------------------------------------------
REPO_DIR="/share/homes/admin/.config-keeper"
BRANCH="main"
GIT_USER="qnap-config-keeper"
GIT_EMAIL="config-keeper@localhost"

# Zu trackende Pfade (Leerzeichen-getrennt)
TRACK_PATHS="/etc/config /etc/crontabs/root"

# QPKG-Liste: Snapshot-Datei im Repo
QPKG_SNAPSHOT="qpkg-list.txt"

# inotifywait-Pfad (Entware)
INOTIFYWAIT="/opt/bin/inotifywait"

# git-Pfad (Entware oder System)
GIT="$(command -v git 2>/dev/null || echo /opt/bin/git)"

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

die() { log "FEHLER: $*" >&2; exit 1; }

require_git() {
    "$GIT" --version >/dev/null 2>&1 || \
        die "git nicht gefunden. Bitte 'opkg install git' ausführen."
}

require_repo() {
    [ -d "$REPO_DIR/.git" ] || \
        die "Repo nicht initialisiert. Zuerst: $0 init"
}

# ---------------------------------------------------------------------------
# Snapshots erstellen (werden ins Repo kopiert)
# ---------------------------------------------------------------------------
snapshot_paths() {
    log "Erstelle Snapshots der Konfigurationsdateien ..."

    for src in $TRACK_PATHS; do
        if [ -e "$src" ]; then
            # Zielverzeichnis im Repo spiegelt den Ursprungspfad
            dst="$REPO_DIR/snapshot${src}"
            mkdir -p "$(dirname "$dst")"
            if [ -d "$src" ]; then
                # Verzeichnis: rsync-Stil via cp -a
                rm -rf "$dst"
                cp -a "$src" "$dst"
            else
                cp -a "$src" "$dst"
            fi
        else
            log "WARNUNG: '$src' existiert nicht, übersprungen."
        fi
    done
}

snapshot_qpkg() {
    log "Erstelle QPKG-Liste ..."
    # /etc/config/qpkg.conf enthält alle installierten QPKGs;
    # zusätzlich geben wir eine lesbare Liste aus falls getcfg verfügbar ist.
    dst="$REPO_DIR/$QPKG_SNAPSHOT"
    if command -v /sbin/getcfg >/dev/null 2>&1 && [ -f /etc/config/qpkg.conf ]; then
        {
            echo "# QPKG-Liste - generiert von qnap-config-keeper"
            echo "# $(date)"
            echo ""
            # Alle QPKG-Sektionen auslesen
            grep '\[' /etc/config/qpkg.conf | tr -d '[]' | while read -r pkg; do
                name=$(/sbin/getcfg "$pkg" Name -f /etc/config/qpkg.conf 2>/dev/null)
                ver=$(/sbin/getcfg "$pkg" Version -f /etc/config/qpkg.conf 2>/dev/null)
                enabled=$(/sbin/getcfg "$pkg" Enable -f /etc/config/qpkg.conf 2>/dev/null)
                printf "%-30s %-15s %s\n" \
                    "${name:-$pkg}" \
                    "${ver:--}" \
                    "$([ "${enabled}" = "TRUE" ] && echo aktiv || echo inaktiv)"
            done
        } > "$dst"
    elif [ -f /etc/config/qpkg.conf ]; then
        cp /etc/config/qpkg.conf "$dst"
    else
        echo "# qpkg.conf nicht gefunden ($(date))" > "$dst"
    fi
}

# ---------------------------------------------------------------------------
# CMD: init
# ---------------------------------------------------------------------------
cmd_init() {
    require_git
    log "Initialisiere Config-Keeper Repo in: $REPO_DIR"
    mkdir -p "$REPO_DIR"
    cd "$REPO_DIR"

    if [ -d ".git" ]; then
        log "Repo existiert bereits. Überspringe 'git init'."
    else
        "$GIT" init -b "$BRANCH" 2>/dev/null || "$GIT" init
        "$GIT" config user.name  "$GIT_USER"
        "$GIT" config user.email "$GIT_EMAIL"
        log "Git-Repo initialisiert."
    fi

    # .gitignore anlegen
    cat > .gitignore << 'EOF'
# Temporäre Dateien
*.tmp
*.swp
*~
.DS_Store
EOF

    # Erster Snapshot + Commit
    snapshot_paths
    snapshot_qpkg
    "$GIT" add -A
    "$GIT" diff --cached --quiet || \
        "$GIT" commit -m "init: erster Snapshot ($(date '+%Y-%m-%d %H:%M:%S'))"
    log "Init abgeschlossen."
}

# ---------------------------------------------------------------------------
# CMD: commit
# ---------------------------------------------------------------------------
cmd_commit() {
    require_git
    require_repo
    cd "$REPO_DIR"

    snapshot_paths
    snapshot_qpkg

    "$GIT" add -A

    if "$GIT" diff --cached --quiet; then
        log "Keine Änderungen – kein Commit nötig."
    else
        # Kurzinfo: welche Dateien geändert
        changed=$("$GIT" diff --cached --name-only | tr '\n' ' ')
        "$GIT" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S') | $changed"
        log "Committed: $changed"
    fi
}

# ---------------------------------------------------------------------------
# CMD: watch  (inotifywait-Loop)
# ---------------------------------------------------------------------------
cmd_watch() {
    require_git
    require_repo

    if [ ! -x "$INOTIFYWAIT" ]; then
        die "inotifywait nicht gefunden unter $INOTIFYWAIT.\n" \
            "Bitte installieren: opkg install inotify-tools"
    fi

    log "Starte inotifywait-Überwachung ..."
    log "Überwachte Pfade: $TRACK_PATHS"
    log "(Strg+C zum Beenden)"

    # Initialer Commit
    cmd_commit

    # Konvertiere TRACK_PATHS zu einzelnen Argumenten
    watch_args=""
    for p in $TRACK_PATHS; do
        [ -e "$p" ] && watch_args="$watch_args $p"
    done
    # qpkg.conf explizit hinzufügen falls vorhanden
    [ -f /etc/config/qpkg.conf ] && watch_args="$watch_args /etc/config/qpkg.conf"

    # Debounce: nach einem Event kurz warten, dann committen
    while true; do
        "$INOTIFYWAIT" \
            -r \
            -e modify,create,delete,move \
            --format '%T %w%f %e' \
            --timefmt '%Y-%m-%d %H:%M:%S' \
            --quiet \
            $watch_args 2>/dev/null && \
        {
            # Kurz warten, falls mehrere Events gleichzeitig kommen
            sleep 2
            cmd_commit
        }
    done
}

# ---------------------------------------------------------------------------
# CMD: install-cron
# ---------------------------------------------------------------------------
cmd_install_cron() {
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    CRON_TAG="# qnap-config-keeper"
    CRONTAB_FILE="/etc/config/crontab"

    # Prüfe ob Cron-Eintrag schon existiert
    if grep -q "qnap-config-keeper" "$CRONTAB_FILE" 2>/dev/null; then
        log "Cron-Job existiert bereits in $CRONTAB_FILE."
        grep "qnap-config-keeper" "$CRONTAB_FILE"
        return
    fi

    # Stündlich um die halbe Stunde
    CRON_LINE="30 * * * *   $SCRIPT_PATH commit >> /var/log/qnap-config-keeper.log 2>&1 $CRON_TAG"

    echo "$CRON_LINE" >> "$CRONTAB_FILE"
    log "Cron-Job hinzugefügt: $CRON_LINE"

    # Cron neu laden (QNAP-Weg)
    if command -v crontab >/dev/null 2>&1; then
        crontab "$CRONTAB_FILE" && log "crontab neu geladen."
    else
        log "Bitte crontab manuell neu laden."
    fi

    log "Alternativ für autorun.sh: Füge folgendes ein:"
    echo "  $SCRIPT_PATH watch &"
}

# ---------------------------------------------------------------------------
# CMD: status / log / diff
# ---------------------------------------------------------------------------
cmd_status() {
    require_git; require_repo
    cd "$REPO_DIR"
    log "=== git status ==="
    "$GIT" status
}

cmd_log() {
    require_git; require_repo
    cd "$REPO_DIR"
    log "=== Letzte 20 Commits ==="
    "$GIT" log --oneline -20
}

cmd_diff() {
    require_git; require_repo
    cd "$REPO_DIR"
    log "=== git diff (unstaged) ==="
    snapshot_paths
    snapshot_qpkg
    "$GIT" add -N --ignore-removal . 2>/dev/null || true
    "$GIT" diff
}

# ---------------------------------------------------------------------------
# Einstiegspunkt
# ---------------------------------------------------------------------------
case "${1:-}" in
    init)          cmd_init         ;;
    commit)        cmd_commit       ;;
    watch)         cmd_watch        ;;
    install-cron)  cmd_install_cron ;;
    status)        cmd_status       ;;
    log)           cmd_log          ;;
    diff)          cmd_diff         ;;
    *)
        echo "Nutzung: $0 {init|commit|watch|install-cron|status|log|diff}"
        echo ""
        echo "  init          Git-Repo anlegen & ersten Snapshot committen"
        echo "  commit        Manuellen Snapshot-Commit durchführen"
        echo "  watch         Dauerhaft per inotifywait überwachen (Foreground)"
        echo "  install-cron  Stündlichen Cron-Job in /etc/config/crontab eintragen"
        echo "  status        git status anzeigen"
        echo "  log           Letzte 20 Commits"
        echo "  diff          Änderungen seit letztem Commit anzeigen"
        exit 1
        ;;
esac
