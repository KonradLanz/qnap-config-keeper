# qnap-config-keeper

**etckeeper for QNAP QTS** — tracks `/etc/config/` and QNAP-specific paths
in a local Git repository on SSD, without ever waking the HDD array.

See [`GOALS.md`](GOALS.md) for the full design rationale, hardware context,
and open decisions.

---

## What is tracked

| Path | Content |
|------|---------|
| `/etc/config/` | Network, users, SMB/NFS, autorun.sh, firewall, smb.conf |
| `/etc/crontabs/root` | Root crontab |
| `qpkg-list.txt` (generated) | Installed QPKGs — name, version, status |
| `docker-compose.yml` / `.env` | Optional, via `DOCKER_COMPOSE_PATHS` |

Passwords (`shadow`, `passwd`), TLS keys, and VPN credentials are **never**
committed — see `.gitignore`.

---

## Prerequisites

```sh
# Entware must be installed
opkg update && opkg install git
```

---

## Quick start

```sh
# 1. Place the script on the SSD share
cp qnap-config-keeper.sh /share/CACHEDEV2_DATA/config-keeper/
chmod +x /share/CACHEDEV2_DATA/config-keeper/qnap-config-keeper.sh

# 2. Initialise — creates the Git repo and first snapshot commit
sh /share/CACHEDEV2_DATA/config-keeper/qnap-config-keeper.sh init

# 3. Set up Cron + autorun.sh (asks for confirmation)
sh /share/CACHEDEV2_DATA/config-keeper/qnap-config-keeper.sh install
```

---

## Commands

| Command | Description |
|---------|-------------|
| `init` | Create Git repo on SSD, write `.gitignore`, initial snapshot commit |
| `snap` | Copy configs into repo, `git diff`, commit only if something changed |
| `status` | Show last commit, diff preview, recent log tail |
| `install` | Add Cron job + `autorun.sh` entry — **always asks for confirmation** |
| `restore FILE` | Restore a single file from the last commit |
| `push` | Explicit opt-in: `git push` to a configured remote |

---

## Logging

| Tier | Path | Content |
|------|------|---------|
| 1 — tmpfs | `/tmp/config-keeper.log` | All log levels (lost on reboot) |
| 2 — SSD | `/share/CACHEDEV2_DATA/config-keeper/keeper.log` | WARN + CRIT only (persistent) |

---

## Configuration

Edit the variables at the top of the script:

```sh
REPO_DIR="/share/CACHEDEV2_DATA/config-keeper"  # Must be on SSD
TRACK_PATHS="/etc/config /etc/crontabs/root"     # Space-separated list
DOCKER_COMPOSE_PATHS=""                          # Optional .yml/.env paths
BRANCH="main"
GIT_USER="qnap-config-keeper"
GIT_EMAIL="config-keeper@localhost"
```

---

## How it works

```
/etc/config/  ─────────────────────────────────┐
/etc/crontabs/root ────────────────────────────┤
docker-compose.yml (optional) ─────────────────┤──► snapshot/ in REPO_DIR (SSD)
qpkg_cli --list ───────────────────────────────┘         │
                                                          ▼
                                                  git add -A
                                                  git commit (only if diff)
                                                          │
                                            ┌─────────────┴──────────────┐
                                            │  Triggers:                 │
                                            │  • Cron (configurable)     │
                                            │  • Manual: snap            │
                                            └────────────────────────────┘
```

---

## Related

- [`qnap-storage-advisor`](https://github.com/KonradLanz/qnap-storage-advisor) — 
  storage analysis + HDD sleep advisor (source of shared patterns)
- [etckeeper](https://etckeeper.branchable.com/) — the inspiration

---

## License

AGPLv3 — see [LICENSE](LICENSE) or https://www.gnu.org/licenses/agpl-3.0.html
