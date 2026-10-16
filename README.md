# server-bootstrap

Turns a fresh Ubuntu Server install into a fleet Docker host: base tools, automatic updates with a 02:00–05:00 reboot window, Docker (official repo), Tailscale, a Hawser agent for Dockhand, the `~/stacks` + `~/projects` layout, shared agent skills, and a per-machine `~/AGENTS.md`.

Built from setting up `lattice` (2026-10). The full walkthrough lives in the *Ubuntu Server Onboarding Runbook* doc.

## Quick start

On the new machine, as your normal user (not root):

```bash
git clone https://github.com/formless63/server-bootstrap ~/projects/server-bootstrap
~/projects/server-bootstrap/bootstrap.sh
```

**Fresh VPS with only root?** Run the same command as root. It asks for a username (or reads `BOOTSTRAP_USER`), creates that user or reuses an existing one, adds it to `sudo`, copies root's `authorized_keys`, copies the repo to the user's `~/projects/server-bootstrap`, then re-runs itself as that user with the same arguments and settings. It only asks you to set a password when the new user has no SSH key or `SUDO_NOPASSWD=0`. Afterwards, log in as the new user; the root copy can be deleted.

```bash
BOOTSTRAP_USER=will ~/projects/server-bootstrap/bootstrap.sh   # as root
```

It asks for your sudo password once, and prints a Tailscale login link to approve (or set `TS_AUTHKEY`). At the end it prints what's left to do by hand, including the Hawser URL and token to add in Dockhand.

Safe to re-run: each step checks the current state first, and existing `compose.yaml`, `.env` and `AGENTS.md` files are never overwritten.

## Phases

| Phase | What it does |
| --- | --- |
| `survey` | Prints OS/hardware/network; warns if the disk is LUKS-encrypted (no unattended boots) |
| `sudo` | Passwordless sudo for your user (needed for agents driven over Remote Control) |
| `tools` | Base CLI tools, `fd`/`bat` aliases |
| `gh` | GitHub CLI from cli.github.com, added to auto-updates |
| `timezone` | Sets `TZ_NAME` |
| `laptop` | Laptops only: ignore lid, mask sleep/suspend/hibernate |
| `updates` | unattended-upgrades reboots when required at `REBOOT_TIME` |
| `docker` | Docker CE + Compose from download.docker.com, `docker` group, Docker in auto-updates |
| `tailscale` | Installs and brings up Tailscale |
| `nonlocal` | `ip_nonlocal_bind=1` so containers can bind the Tailscale IP at boot |
| `layout` | `~/stacks`, `~/projects`, `~/.agents/skills` (+ `~/.claude/skills` symlink), syncs `skills/`, `~/CLAUDE.md` |
| `hawser` | `~/stacks/hawser` in standard mode on `<tailscale-ip>:2376` with a fresh token, started |
| `pangolin` | `~/stacks/pangolin-cli` template + `.env` (not started; needs site credentials) |
| `agents` | Installs Claude Code and Codex; links `~/.codex/AGENTS.md` to `~/AGENTS.md` |
| `agentsmd` | Generates `~/AGENTS.md` from what it detected |
| `verify` | Checks containers, Hawser health, auto-updates, failed units, firmware updates |

Run part of it: `./bootstrap.sh --only docker,verify` or `./bootstrap.sh --skip agents`.

## Settings (environment variables)

| Variable | Default |
| --- | --- |
| `BOOTSTRAP_USER` | empty; only used when run as root (prompts if unset, defaulting to the UID 1000 user) |
| `TZ_NAME` | `America/New_York` |
| `REBOOT_TIME` | `03:00` (keep it within 02:00–05:00) |
| `SUDO_NOPASSWD` | `1` |
| `TS_AUTHKEY` | empty, so you approve a login link interactively |
| `INSTALL_CLAUDE` | `1` |
| `INSTALL_CODEX` | `1` |
| `DOCKER_FALLBACK_CODENAME` | `noble`, used if Docker has no repo for a brand-new Ubuntu release yet |

## GitHub login and git identity (once per machine)

```bash
gh auth login --hostname github.com --git-protocol https --web   # device code; approve at github.com/login/device
gh auth setup-git                                                # git uses gh for HTTPS credentials
git config --global user.name  "<name>"
git config --global user.email "<id>+<user>@users.noreply.github.com"   # or your real email
git config --global init.defaultBranch main
```

## Deliberately not automated

- Firmware installs (`fwupdmgr update` + manual reboot): an unattended BIOS flash can brick a headless box.
- BIOS settings: AC power recovery, laptop battery charge limit.
- Firewall, SSH hardening, backups, router DHCP reservations.

## Skills

`skills/` is the canonical copy of the shared agent skills. The `layout` phase syncs it into `~/.agents/skills/` and **overwrites local edits**, so change skills here, commit, and re-run `./bootstrap.sh --only layout` on each machine.
