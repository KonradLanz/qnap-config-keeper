# Project Goals — qnap-config-keeper

> Living document. Update this file whenever scope or design decisions change.
> Every new chat session should read this file first to restore full context.

---

## One-liner

**etckeeper for QNAP QTS** — version-control `/etc/config/` and QNAP-specific paths
in a local Git repo on SSD, without ever waking the HDD array.

---

## Hardware Context

| Device | Type | Array | Mount | Role |
|--------|------|-------|-------|------|
| `sda` | SATA SSD 465 GB | `md2` | `/share/CACHEDEV2_DATA` | **Git repo lives here** |
| `sdb–sdg` | 6× HDD 4 TB | `md1` RAID6 | `/share/CACHEDEV1_DATA` | Should sleep at night — never touched by this tool |
| `/mnt/ext` | USB/Flash 416 MB | — | — | Out of scope (92 % full) |

- Shell: **busybox ash** — no `set -u`, no bash-only syntax
- Package manager: Entware (`opkg install git`)
- NAS model: QNAP TVS-x73e, QTS

---

## What Is Tracked

### Always

| Path | Content |
|------|---------|
| `/etc/config/` | Network (bonding, VLANs), users, groups, SMB/NFS shares, autorun.sh, smb.conf, firewall, stunnel, Apache reverse-proxy rules |
| `/etc/crontabs/root` | Root crontab |
| `qpkg-list.txt` (generated) | Installed QPKGs with version + status (`qpkg_cli --list`) |

### Optional (configurable via `DOCKER_COMPOSE_PATHS`)

Docker-compose files for self-hosted services, e.g.:

```
/share/CACHEDEV2_DATA/paperless-ngx-qnap/docker-compose.yml
/share/CACHEDEV2_DATA/paperless-ngx-qnap/.env
```

---

## What Is Explicitly NOT Tracked

| Path / Pattern | Reason |
|----------------|--------|
| `snapshot/etc/config/shadow*` | Password hashes (SHA-512-crypt) |
| `snapshot/etc/config/passwd` | UIDs, home dirs |
| `snapshot/etc/config/ssl/` | TLS private keys + certificates |
| `snapshot/etc/config/*key*`, `*.pem`, `*.pfx` | Any private key material |
| `snapshot/etc/config/openvpn/` | VPN credentials |
| Binaries, log files, media | Only configs, no data |

All of the above are covered by `.gitignore` — they are **never committed**.

---

## Design Decisions

### Repo location

`/share/CACHEDEV2_DATA/config-keeper/` — SSD pool, survives reboots,
never causes HDD wake-up.

### Two-tier logging (same pattern as `qnap-storage-advisor`)

| Tier | Path | What goes there |
|------|------|-----------------|
| 1 — tmpfs | `/tmp/config-keeper.log` | All levels (DEBUG, INFO, WARN, CRIT) |
| 2 — SSD | `/share/CACHEDEV2_DATA/config-keeper/keeper.log` | WARN and CRIT only |

Rationale: tmpfs is lost on reboot (fine for recent context); SSD log survives
and is small because only important events are written there.

### No automatic remote push

The tool **never pushes to GitHub automatically**. Remote operations are always
explicit opt-in via `qnap-config-keeper.sh push` or a manual `git push`.

### HDD sleep is sacred

`path_is_rotational()` (ported from `qnap-storage-advisor`) guards the repo
location at `init` time. If `REPO_DIR` is on a rotational device, the tool
will print a WARN and refuse to continue.

---

## Command Interface

```
qnap-config-keeper.sh init             # Create Git repo, initial snapshot + commit
qnap-config-keeper.sh snap             # Snapshot: copy configs, git diff, commit if changed
qnap-config-keeper.sh status           # Last commit, diff preview, log tail
qnap-config-keeper.sh install          # Add Cron job + autorun.sh entry (asks for confirmation)
qnap-config-keeper.sh restore FILE     # Restore single file from last commit
qnap-config-keeper.sh push             # Explicit opt-in: git push to configured remote
```

---

## Patterns Borrowed from `qnap-storage-advisor`

| Pattern | Where used |
|---------|------------|
| `path_is_rotational()` | Guard in `init`: warn if repo is on HDD |
| TTY colour guard (`[ -t 1 ]`) | No ANSI escapes in Cron log output |
| `say / ok / warn / fail` levels | All output functions |
| `do_install` Cron + autorun.sh pattern | `install` command |
| busybox-ash-compatible `sh` | No `set -u`, no bash arrays, no `[[` |

Reference: https://github.com/KonradLanz/qnap-storage-advisor

---

## Open Decisions (to be resolved)

| # | Question | Status |
|---|----------|--------|
| 1 | Which additional sensitive files in `/etc/config/` to exclude beyond the defaults? | ⏳ Pending |
| 2 | `push` command: full subcommand or just a hint in `status` output? | ⏳ Pending |
| 3 | Cron interval: hourly / 4×day / nightly? | ⏳ Pending |

---

## Non-Goals

- Not a backup tool (no block-level or binary backup)
- Not a monitoring/alerting tool (see `qnap-storage-advisor` for that)
- Not a secrets manager
- Does not replace QNAP's built-in config backup

---

*Last updated: 2026-05-10*
