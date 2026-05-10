# qnap-config-keeper

Ein **etckeeper-Äquivalent** speziell für QNAP QTS (busybox ash + Entware).  
Trackt Konfigurationsänderungen in einem lokalen Git-Repository und committet automatisch via Cron oder `inotifywait`.

## Was wird getrackt

| Pfad | Inhalt |
|---|---|
| `/etc/config/` | Netzwerk, User, Dienste, autorun.sh, qpkg.conf |
| `/etc/crontabs/root` | Root-Crontab |
| `qpkg-list.txt` (Snapshot) | Installierte QPKGs mit Version & Status |

## Voraussetzungen

```sh
# Entware muss installiert sein
opkg update
opkg install git
opkg install inotify-tools   # Optional, nur für 'watch'-Modus
```

## Installation

```sh
# Skript ins System legen
cp qnap-config-keeper.sh /share/homes/admin/qnap-config-keeper.sh
chmod +x /share/homes/admin/qnap-config-keeper.sh

# Repo initialisieren (legt /share/homes/admin/.config-keeper an)
/share/homes/admin/qnap-config-keeper.sh init
```

## Nutzung

```sh
# Sofort-Commit (manuell)
qnap-config-keeper.sh commit

# Dauerhaft überwachen via inotifywait (Foreground)
qnap-config-keeper.sh watch

# Stündlichen Cron-Job einrichten
qnap-config-keeper.sh install-cron

# Status / History
qnap-config-keeper.sh status
qnap-config-keeper.sh log
qnap-config-keeper.sh diff
```

## Konfiguration

Am Anfang des Skripts anpassbare Variablen:

```sh
REPO_DIR="/share/homes/admin/.config-keeper"  # Wo das Git-Repo liegt
TRACK_PATHS="/etc/config /etc/crontabs/root"   # Zu trackende Pfade
BRANCH="main"                                  # Git-Branch-Name
```

## Autostart nach Reboot

In `/etc/config/autorun.sh` einfügen (watch-Modus):

```sh
# qnap-config-keeper im Hintergrund starten
/share/homes/admin/qnap-config-keeper.sh watch >> /var/log/qnap-config-keeper.log 2>&1 &
```

Oder nur Cron nutzen (empfohlen für Stabilität):

```sh
qnap-config-keeper.sh install-cron
```

## Wie es funktioniert

```
┌─────────────────────────────────────────────────────────┐
│  QNAP QTS                                               │
│                                                         │
│  /etc/config/  ──────────┐                              │
│  /etc/crontabs/root ─────┤──► snapshot in REPO_DIR     │
│  qpkg.conf (QPKG-Liste)──┘         │                    │
│                                    ▼                    │
│                            git add -A                   │
│                            git commit                   │
│                                    │                    │
│                        ┌───────────┴───────────┐        │
│                        │ Trigger-Optionen:     │        │
│                        │  • Cron (stündlich)   │        │
│                        │  • inotifywait watch  │        │
│                        │  • Manuell: commit    │        │
│                        └───────────────────────┘        │
└─────────────────────────────────────────────────────────┘
```

## Hinweise

- Das Git-Repo liegt auf einer persistenten Share (`/share/homes/admin/`), damit es Reboots überlebt.
- `/etc/config/` wird von QNAP nach jedem Reboot aus dem Flash neu geladen – daher ist das Tracking von Änderungen *während* der Laufzeit wichtig.
- Die QPKG-Liste (`qpkg-list.txt`) wird bei jedem Commit neu generiert.
- Log-Datei: `/var/log/qnap-config-keeper.log`
