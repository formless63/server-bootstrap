#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu Server into a fleet Docker host:
# base tools, auto-updates with a reboot window, Docker, Tailscale, Hawser,
# ~/stacks + ~/projects layout, agent skills and a per-machine AGENTS.md.
#
# Safe to re-run: every step checks before it changes anything.
# Usage: ./bootstrap.sh [--skip a,b] [--only a,b] [--list] [--help]
# shellcheck disable=SC2088  # "~" in messages is display text
set -euo pipefail

# ---- Settings (override via environment, e.g. TZ_NAME=UTC ./bootstrap.sh) ----
TZ_NAME="${TZ_NAME:-America/New_York}"
REBOOT_TIME="${REBOOT_TIME:-03:00}"          # must fall in the 02:00-05:00 window
SUDO_NOPASSWD="${SUDO_NOPASSWD:-1}"          # needed for agents driven via Remote Control
TS_AUTHKEY="${TS_AUTHKEY:-}"                 # optional; otherwise `tailscale up` prints a login link
INSTALL_CLAUDE="${INSTALL_CLAUDE:-1}"
INSTALL_CODEX="${INSTALL_CODEX:-1}"
DOCKER_FALLBACK_CODENAME="${DOCKER_FALLBACK_CODENAME:-noble}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACKS_DIR="$HOME/stacks"
PROJECTS_DIR="$HOME/projects"
SKILLS_DIR="$HOME/.agents/skills"
HOST_NAME="$(hostname -s)"
LOG="$HOME/bootstrap-$(date +%Y%m%d-%H%M%S).log"

PHASES=(survey sudo tools gh timezone laptop updates docker tailscale nonlocal layout hawser pangolin agents agentsmd verify)

# ---- Helpers ----
c_bold=$'\e[1m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_red=$'\e[31m'; c_off=$'\e[0m'
say()  { printf '%s==> %s%s\n' "$c_bold" "$*" "$c_off"; }
ok()   { printf '    %s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '    %s!%s %s\n' "$c_yellow" "$c_off" "$*"; WARNINGS+=("$*"); }
die()  { printf '%sError:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
WARNINGS=()
NOTES=()

# Write content to a root-owned file only if it differs; returns 0 if changed.
put_root_file() {
  local path="$1" content="$2"
  if [[ -f "$path" ]] && [[ "$(sudo cat "$path")" == "$content" ]]; then
    ok "$path already set"; return 1
  fi
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  ok "wrote $path"
}

is_laptop() {
  local t; t="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)"
  case "$t" in 8|9|10|14|31|32) return 0 ;; esac
  compgen -G '/sys/class/power_supply/BAT*' >/dev/null
}

ts_ip() { tailscale ip -4 2>/dev/null | head -1; }

# ---- Phases ----
phase_survey() {
  say "Survey"
  . /etc/os-release
  [[ "$ID" == "ubuntu" ]] || die "This script targets Ubuntu (found $ID)."
  ok "$PRETTY_NAME ($VERSION_CODENAME), kernel $(uname -r)"
  ok "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null), $(nproc) cores, $(free -h | awk '/Mem:/{print $2}') RAM"
  is_laptop && ok "Laptop detected: lid/sleep phase will apply" || ok "Not a laptop"
  if lsblk -o FSTYPE | grep -q crypto_LUKS; then
    warn "Disk is LUKS-encrypted: it needs a passphrase at every boot, including 03:00 auto-reboots."
  fi
  ip -br -4 addr | grep -Ev '^(lo|docker|br-|veth)' | sed 's/^/    /'
}

phase_sudo() {
  say "Passwordless sudo"
  local f="/etc/sudoers.d/$USER"
  if [[ "$SUDO_NOPASSWD" != 1 ]]; then ok "skipped (SUDO_NOPASSWD=0)"; return; fi
  if sudo test -f "$f"; then
    sudo chmod 0440 "$f"; ok "$f exists (mode 0440)"
  else
    local tmp; tmp="$(mktemp)"
    echo "$USER ALL=(ALL) NOPASSWD: ALL" > "$tmp"
    sudo visudo -cf "$tmp" >/dev/null || die "sudoers validation failed"
    sudo install -m 0440 -o root -g root "$tmp" "$f"; rm -f "$tmp"
    ok "created $f"
  fi
}

phase_tools() {
  say "Base tools"
  local pkgs=(curl wget git vim nano htop tmux jq rsync lsof dnsutils unzip zip tree ncdu btop
              ripgrep fd-find bat mtr-tiny iotop-c smartmontools build-essential ca-certificates
              gnupg bash-completion gettext-base fwupd)
  if [[ -z "$(systemd-detect-virt 2>/dev/null | grep -v none)" ]]; then pkgs+=(lm-sensors nvme-cli); fi
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
  ok "installed ${#pkgs[@]} packages"
  if ! grep -q 'alias fd=fdfind' "$HOME/.bashrc"; then
    printf '\nalias fd=fdfind\nalias bat=batcat\n' >> "$HOME/.bashrc"; ok "added fd/bat aliases"
  else ok "fd/bat aliases present"; fi
}

phase_gh() {
  say "GitHub CLI (official repo)"
  if [[ ! -s /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    ok "added GitHub CLI signing key"
  fi
  put_root_file /etc/apt/sources.list.d/github-cli.list \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" || true
  if ! command -v gh >/dev/null; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh >/dev/null
  fi
  ok "$(gh --version | head -1)"
  put_root_file /etc/apt/apt.conf.d/51gh-auto-update '// Auto-update GitHub CLI from cli.github.com
Unattended-Upgrade::Allowed-Origins {
	"gh:stable";
};' || true
  if gh auth status >/dev/null 2>&1; then ok "gh logged in"
  else NOTES+=("GitHub: gh auth login --web --git-protocol https, then gh auth setup-git; set git user.name/user.email (see README)."); fi
}

phase_timezone() {
  say "Timezone"
  if [[ "$(timedatectl show -p Timezone --value)" == "$TZ_NAME" ]]; then ok "already $TZ_NAME"
  else sudo timedatectl set-timezone "$TZ_NAME"; ok "set to $TZ_NAME"; fi
}

phase_laptop() {
  say "Laptop: ignore lid, disable sleep"
  if ! is_laptop; then ok "not a laptop, skipped"; return; fi
  sudo mkdir -p /etc/systemd/logind.conf.d
  if put_root_file /etc/systemd/logind.conf.d/server.conf "[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore"; then sudo systemctl kill -s HUP systemd-logind; fi
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
  ok "sleep/suspend/hibernate/hybrid-sleep masked"
  NOTES+=("BIOS (laptop): set a battery charge limit (lattice uses start 50% / stop 90%).")
}

phase_updates() {
  say "Automatic updates + ${REBOOT_TIME} reboot window"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
  put_root_file /etc/apt/apt.conf.d/52auto-reboot "Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"${REBOOT_TIME}\";" || true
}

phase_docker() {
  say "Docker (official repo)"
  . /etc/os-release
  local codename="$VERSION_CODENAME"
  # Docker's repo serves InRelease only; a HEAD on Release 404s even for supported releases.
  if ! curl -fsS -o /dev/null "https://download.docker.com/linux/ubuntu/dists/$codename/InRelease"; then
    warn "Docker has no repo for '$codename' yet; using '$DOCKER_FALLBACK_CODENAME'."
    codename="$DOCKER_FALLBACK_CODENAME"
  fi
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    ok "added Docker signing key"
  fi
  put_root_file /etc/apt/sources.list.d/docker.list \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" || true
  if ! command -v docker >/dev/null; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    ok "installed $(sudo docker version --format 'Docker {{.Server.Version}}')"
  else ok "already installed: $(sudo docker version --format 'Docker {{.Server.Version}}' 2>/dev/null)"; fi
  sudo systemctl enable --now docker >/dev/null 2>&1
  if id -nG "$USER" | grep -qw docker; then ok "$USER in docker group"
  else sudo usermod -aG docker "$USER"; ok "added $USER to docker group (log out/in to use without sudo)"; fi
  put_root_file /etc/apt/apt.conf.d/51docker-auto-update '// Auto-update Docker CE from the official Docker repo
Unattended-Upgrade::Allowed-Origins {
	"Docker:${distro_codename}";
};' || true
}

phase_tailscale() {
  say "Tailscale"
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
    ok "installed"
  else ok "already installed"; fi
  if [[ -n "$(ts_ip)" ]]; then ok "up: $(ts_ip)"; return; fi
  if [[ -n "$TS_AUTHKEY" ]]; then
    sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$HOST_NAME"
  else
    echo "    Open the login link below to add this machine to your tailnet:"
    sudo tailscale up --hostname="$HOST_NAME"
  fi
  [[ -n "$(ts_ip)" ]] && ok "up: $(ts_ip)" || warn "Tailscale is not up; the Hawser phase will be skipped."
}

phase_nonlocal() {
  say "Allow binding the Tailscale IP before it exists (boot race)"
  if put_root_file /etc/sysctl.d/60-nonlocal-bind.conf "# Let Docker bind published ports to the Tailscale IP before tailscaled has assigned it
net.ipv4.ip_nonlocal_bind = 1
net.ipv6.ip_nonlocal_bind = 1"; then sudo sysctl --system >/dev/null; fi
}

phase_layout() {
  say "Directory layout, skills, CLAUDE.md"
  mkdir -p "$STACKS_DIR" "$PROJECTS_DIR" "$SKILLS_DIR" "$HOME/.claude"
  ok "$STACKS_DIR, $PROJECTS_DIR, $SKILLS_DIR"
  if [[ -e "$HOME/.claude/skills" && ! -L "$HOME/.claude/skills" ]]; then
    warn "~/.claude/skills is a real directory; not replacing it with a symlink."
  else ln -sfn "$SKILLS_DIR" "$HOME/.claude/skills"; ok "~/.claude/skills -> $SKILLS_DIR"; fi
  local s
  for s in "$REPO_DIR"/skills/*/; do
    s="$(basename "$s")"
    rsync -a --delete "$REPO_DIR/skills/$s/" "$SKILLS_DIR/$s/"
    ok "skill: $s (synced from repo)"
  done
  [[ -f "$HOME/CLAUDE.md" ]] || { echo '@AGENTS.md' > "$HOME/CLAUDE.md"; ok "created ~/CLAUDE.md"; }
}

phase_hawser() {
  say "Hawser (standard mode over Tailscale)"
  local dir="$STACKS_DIR/hawser" ip; ip="$(ts_ip)"
  if [[ -z "$ip" ]]; then warn "No Tailscale IP; skipping Hawser."; return; fi
  mkdir -p "$dir"
  if [[ ! -f "$dir/compose.yaml" ]]; then
    STACKS_DIR="$STACKS_DIR" HOST_NAME="$HOST_NAME" envsubst '${STACKS_DIR} ${HOST_NAME}' \
      < "$REPO_DIR/templates/hawser/compose.yaml" > "$dir/compose.yaml"
    ok "wrote $dir/compose.yaml"
  else ok "compose.yaml exists, left as-is"; fi
  if [[ ! -f "$dir/.env" ]]; then
    ( umask 077; printf '# Standard mode: Dockhand connects to http://%s:2376 with this token\nTAILSCALE_IP=%s\nTOKEN=%s\n' \
        "$ip" "$ip" "$(openssl rand -hex 32)" > "$dir/.env" )
    ok "wrote $dir/.env with a new token"
  else ok ".env exists, left as-is"; fi
  sudo docker compose -f "$dir/compose.yaml" up -d --quiet-pull 2>&1 | tail -1 | sed 's/^/    /'
  NOTES+=("Dockhand: add environment http://$ip:2376 with the TOKEN from $dir/.env")
}

phase_pangolin() {
  say "Pangolin connector stack (template only)"
  local dir="$STACKS_DIR/pangolin-cli"
  if [[ -f "$dir/compose.yaml" ]]; then ok "exists, left as-is"; return; fi
  mkdir -p "$dir"
  HOST_NAME="$HOST_NAME" envsubst '${HOST_NAME}' < "$REPO_DIR/templates/pangolin-cli/compose.yaml" > "$dir/compose.yaml"
  ( umask 077; cp "$REPO_DIR/templates/pangolin-cli/.env.example" "$dir/.env" )
  ok "wrote $dir/compose.yaml + .env (not started)"
  NOTES+=("Pangolin: add site IDs/secrets to $dir/.env, adjust sites in compose.yaml, then: docker compose up -d")
}

phase_agents() {
  say "Coding agents: Claude Code + Codex"
  if [[ "$INSTALL_CLAUDE" == 1 ]]; then
    if command -v claude >/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; then ok "Claude Code already installed"
    elif curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then ok "Claude Code installed (run 'claude' in ~ to log in)"
    else warn "Claude Code install failed; install it manually."; fi
  else ok "Claude Code skipped (INSTALL_CLAUDE=0)"; fi
  if [[ "$INSTALL_CODEX" == 1 ]]; then
    if command -v codex >/dev/null || [[ -x "$HOME/.local/bin/codex" ]]; then ok "Codex already installed"
    elif curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh >/dev/null 2>&1; then ok "Codex installed (run 'codex login')"
    else warn "Codex install failed; install it manually."; fi
    # Codex reads global instructions from ~/.codex/AGENTS.md; point it at the machine's AGENTS.md
    mkdir -p "$HOME/.codex"
    if [[ ! -e "$HOME/.codex/AGENTS.md" ]]; then ln -s "$HOME/AGENTS.md" "$HOME/.codex/AGENTS.md"; ok "linked ~/.codex/AGENTS.md -> ~/AGENTS.md"
    else ok "~/.codex/AGENTS.md exists"; fi
  else ok "Codex skipped (INSTALL_CODEX=0)"; fi
}

phase_agentsmd() {
  say "AGENTS.md"
  local f="$HOME/AGENTS.md"
  if [[ -f "$f" ]]; then ok "exists, left as-is (agents keep it current)"; return; fi
  . /etc/os-release
  local hw ip4 ram disk laptop ts
  hw="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  ram="$(free -h | awk '/Mem:/{print $2}')"
  disk="$(df -h / | awk 'NR==2{print $1" ("$2")"}')"
  ip4="$(ip -br -4 addr | awk '$1!~/^(lo|docker|br-|veth|tailscale)/ {print $1" "$3}' | paste -sd ';' -)"
  ts="$(ts_ip)"; ts="${ts:-not connected}"
  is_laptop && laptop="**laptop** used as a server; lid switch ignored, sleep targets masked" || laptop="not a laptop"
  cat > "$f" <<EOF
# ${HOST_NAME}: fleet server

Orientation for any agent working on this machine. Read this file before changing anything, and keep it updated: when you install, configure or discover something, add it here (and to the changelog at the bottom). Created by server-bootstrap; fill in anything marked TODO.

## Machine

| | |
|---|---|
| Hostname | \`${HOST_NAME}\` |
| Hardware | ${hw}, $(nproc) cores, ${ram} RAM; ${laptop} |
| OS | ${PRETTY_NAME} "${VERSION_CODENAME}", kernel $(uname -r) |
| Root disk | ${disk} |
| Network | ${ip4} (TODO: confirm router DHCP reservation) |
| Tailscale | ${ts} |
| Timezone | ${TZ_NAME} |
| User | \`${USER}\` (passwordless sudo via \`/etc/sudoers.d/${USER}\`; member of \`docker\`) |

## Layout and conventions

| Path | Purpose |
|---|---|
| \`~/stacks/<name>/\` | **Compose stacks that actually run.** Managed via Dockhand (through Hawser). \`compose.yaml\` + \`.env\` + bind-mounted data. |
| \`~/projects/<name>/\` | Dev projects (git repos) with example compose; the copy we run/test lives in \`~/stacks/<name>/\`. |
| \`~/.agents/skills/\` | Agent skills (canonical). \`~/.claude/skills\` is a symlink to it. |

For any new project or stack, use the **\`new-project\` skill**: explicit names everywhere, \`restart: unless-stopped\`, public apps on the \`pangolin\` network, internal tools bound to \`\${TAILSCALE_IP}\`.

## Installed / configured

- **Base tools** (curl, git, vim, tmux, jq, btop, ncdu, ripgrep, fd→\`fdfind\`, bat→\`batcat\`, smartmontools, …), installed by server-bootstrap.
- **Docker** from the official repo, Compose v5 plugin. Auto-updated with Ubuntu (\`/etc/apt/apt.conf.d/51docker-auto-update\`).
- **Automatic updates:** reboot when required at **${REBOOT_TIME}** (\`/etc/apt/apt.conf.d/52auto-reboot\`). **No reboots or disruptive maintenance outside 02:00 to 05:00.**
- **Hawser** (\`~/stacks/hawser/\`): standard mode on \`${ts}:2376\`, token in \`.env\`. Manage this stack from the CLI, not Dockhand.
- **Pangolin connectors** (\`~/stacks/pangolin-cli/\`): TODO, list sites once configured. Only one connector per host mounts the Docker socket.
- **Firmware:** fwupd. Updates are checked automatically but installed **manually** (\`fwupdmgr update\` + a manual reboot).
- **Boot race fix:** \`ip_nonlocal_bind=1\` (\`/etc/sysctl.d/60-nonlocal-bind.conf\`) so containers can bind the Tailscale IP before tailscaled is up.

## Networking / access model

- Public apps go through Pangolin with no published ports. Internal tools publish only on the Tailscale IP. Nothing is reachable from the WAN; no router port-forwards.
- Firewall (ufw): TODO, record its state. Docker-published ports bypass ufw.

## Known issues / gotchas

- Remote Control clients can't run \`!\` commands (they arrive as chat). Agents run commands themselves.
- Docker auto-updates restart the daemon, which briefly stops containers; restart policies bring them back.

## Pending / TODO

- [ ] BIOS: AC power recovery on$(is_laptop && printf "; battery charge limit" || true)
- [ ] Router DHCP reservation
- [ ] Pangolin site credentials
- [ ] SSH hardening, backups

## Changelog

- $(date +%F): Bootstrapped with server-bootstrap.
EOF
  ok "wrote $f (review the TODOs)"
}

phase_verify() {
  say "Verify"
  local c
  sudo docker ps --format '{{.Names}}\t{{.Status}}' | sed 's/^/    /'
  if [[ -n "$(ts_ip)" ]] && curl -fsS -m 3 "http://$(ts_ip):2376/_hawser/health" >/dev/null 2>&1; then ok "Hawser health OK"
  elif [[ -n "$(ts_ip)" ]]; then warn "Hawser health check failed (it may still be starting)."; fi
  [[ "$(sysctl -n net.ipv4.ip_nonlocal_bind)" == 1 ]] && ok "ip_nonlocal_bind = 1" || warn "ip_nonlocal_bind not set"
  # Capture before grepping: `grep -q` + pipefail reports SIGPIPE'd producers as failures
  local out
  out="$(apt-config dump)"
  [[ "$out" == *'Automatic-Reboot "true"'* ]] && ok "auto-reboot on at $REBOOT_TIME" || warn "auto-reboot not configured"
  out="$(sudo unattended-upgrade --dry-run --debug 2>&1 || true)"
  [[ "$out" == *'o=Docker'* ]] && ok "unattended-upgrades includes Docker" || warn "Docker not in unattended-upgrades origins"
  c="$(systemctl --failed --no-legend | wc -l)"; [[ "$c" == 0 ]] && ok "no failed units" || warn "$c failed systemd unit(s)"
  if command -v fwupdmgr >/dev/null && fwupdmgr get-updates --no-unreported-check </dev/null >/dev/null 2>&1; then
    NOTES+=("Firmware updates available: fwupdmgr get-updates, then fwupdmgr update + reboot.")
  fi
}

# ---- CLI ----
usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  echo; echo "Phases: ${PHASES[*]}"
  echo "Env: TZ_NAME REBOOT_TIME SUDO_NOPASSWD TS_AUTHKEY INSTALL_CLAUDE INSTALL_CODEX DOCKER_FALLBACK_CODENAME"
}
SKIP=""; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip) SKIP="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --list) echo "${PHASES[*]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ $EUID -ne 0 ]] || die "Run as your normal user (the script uses sudo itself)."
for p in ${SKIP//,/ } ${ONLY//,/ }; do [[ " ${PHASES[*]} " == *" $p "* ]] || die "unknown phase: $p"; done

exec > >(tee -a "$LOG") 2>&1
echo "server-bootstrap on $HOST_NAME, $(date). Log: $LOG"
sudo -n true 2>/dev/null || sudo -v || die "sudo is required"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &

for p in "${PHASES[@]}"; do
  [[ -n "$ONLY" && ",$ONLY," != *",$p,"* ]] && continue
  [[ ",$SKIP," == *",$p,"* ]] && continue
  "phase_$p"
done

echo
say "Done"
for n in "${NOTES[@]}"; do printf '    • %s\n' "$n"; done
printf '    • %s\n' "Still manual: BIOS AC power recovery, router DHCP reservation, SSH hardening, backups." \
  "Log out and back in to use docker without sudo."
if ((${#WARNINGS[@]})); then echo; say "Warnings"; for w in "${WARNINGS[@]}"; do printf '    %s!%s %s\n' "$c_yellow" "$c_off" "$w"; done; fi
