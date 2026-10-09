#!/usr/bin/env bash
#
# homelab-panel installer
# =======================
#
# This script puts homelab-panel on your Proxmox VE cluster. Run it as root on any one of your
# Proxmox nodes:
#
#   bash -c "$(curl -fsSL https://github.com/jjackb14/homelab-panel-releases/releases/latest/download/install.sh)"
#
# What it does, in order:
#
#   1. Asks you a few questions, on menu screens like the community-scripts installers use.
#      "Default Install" picks sensible settings for you; "Advanced Install" lets you choose
#      each one.
#   2. Downloads the panel and its files from the same GitHub release this script came from,
#      and checks each one against its published checksum. If anything doesn't match, it stops
#      before changing anything on your cluster.
#   3. Creates a small Debian 13 container (an "LXC") to run the panel in.
#   4. Installs the panel inside it as a system service, running as its own user (not root).
#   5. Creates a Proxmox API user (panel@pve) and token for the panel, allowed only the
#      things the panel needs.
#   6. Gives the panel its own SSH key, so it can run upgrades and move files on your nodes.
#      Adding that key to your nodes is something it asks you about first.
#   7. Optionally installs Tailscale in the container, so you can reach the panel from your
#      phone or laptop anywhere on your tailnet.
#   8. Sets the password for the panel's sign-in page, starts the panel, and prints its address.
#
# If a step fails, the script says which one, lists what it had already created, and gives you
# the command that removes each of those things.
#
# Running it without the screens
# ------------------------------
# Every question can be answered ahead of time with an environment variable, using the same
# names as community-scripts (var_ctid, var_disk, var_net, ...; the full list is just below).
# With NONINTERACTIVE=1 the script shows no screens at all; it then reads the panel's password
# from a file you name in var_password_file. For example:
#
#   NONINTERACTIVE=1 var_ctid=150 var_tailscale=no var_add_key=yes \
#     var_password_file=/root/panel-password bash install.sh
#
# This is not community-scripts' code: it is written for homelab-panel, and nothing is
# downloaded from community-scripts while it runs.

# Stop at the first command that fails (-e), including inside pipelines (pipefail) and
# functions (-E), and treat a misspelled variable as an error (-u). The "on_error" function
# further down then explains what happened.
set -Eeuo pipefail

# Which release this script belongs to. Each release's copy of this script has its own version
# written here, so it always downloads the files of that same release and never mixes versions.
# A copy that still says "dev" did not come from a release, and refuses to run.
VERSION=${VERSION:-v0.1.0}
REPO=jjackb14/homelab-panel-releases
RELEASE_BASE=https://github.com/$REPO/releases/download/$VERSION
# The panel itself: one program file, built for 64-bit Intel/AMD Linux.
ASSET=homelab-panel-x86_64-unknown-linux-gnu
APP=homelab-panel
# Where Proxmox keeps each container's settings file. (The project's tests point this at a
# scratch folder; on a real node it is always /etc/pve/lxc.)
PVE_LXC_DIR=${PVE_LXC_DIR:-/etc/pve/lxc}

# --- Settings --------------------------------------------------------------------------------
# Each line reads a setting from the environment if you set one, and otherwise uses the value
# after ":-", which is what "Default Install" uses. Blank means "work it out" or "none".
#
#   var_ctid               container ID (default: the next free ID in your cluster)
#   var_hostname           the container's name, also its name on your tailnet
#   var_disk               disk size in GB
#   var_cpu                CPU cores
#   var_ram                memory in MiB
#   var_unprivileged       1 = unprivileged container (recommended), 0 = privileged
#   var_brg                network bridge to connect to
#   var_net                "dhcp", or a fixed address with its prefix, like 10.0.0.50/24
#   var_gateway            the gateway, for a fixed address
#   var_ipv6_method        none, auto, dhcp or static (then var_ipv6_addr and var_ipv6_gw)
#   var_mtu                network MTU (blank = the bridge's default)
#   var_searchdomain       DNS search domain (blank = the node's)
#   var_ns                 DNS server (blank = the node's, see preflight below)
#   var_mac                network card's MAC address (blank = random)
#   var_vlan               VLAN tag (blank = none)
#   var_tags               Proxmox tags for the container, separated by ";"
#   var_ssh                yes = let root log in to the container over SSH
#   var_pw                 root password for the container's console (blank = log in automatically)
#   var_verbose            yes = show the full output of every command
#   var_template_storage   where to keep the Debian template (blank = ask, if there is a choice)
#   var_container_storage  where to put the container's disk (blank = ask, if there is a choice)
#   var_tailscale          yes/no: install Tailscale in the container (blank = ask)
#   var_add_key            yes/no: add the panel's SSH key to your nodes (blank = ask)
#   var_password_file      a file holding the panel's sign-in password (unattended installs)
var_ctid=${var_ctid:-}
var_hostname=${var_hostname:-homelab-panel}
var_disk=${var_disk:-4}
var_cpu=${var_cpu:-1}
var_ram=${var_ram:-512}
var_unprivileged=${var_unprivileged:-1}
var_brg=${var_brg:-vmbr0}
var_net=${var_net:-dhcp}
var_gateway=${var_gateway:-}
var_ipv6_method=${var_ipv6_method:-none}
var_ipv6_addr=${var_ipv6_addr:-}
var_ipv6_gw=${var_ipv6_gw:-}
var_mtu=${var_mtu:-}
var_searchdomain=${var_searchdomain:-}
var_ns=${var_ns:-}
var_mac=${var_mac:-}
var_vlan=${var_vlan:-}
var_tags=${var_tags:-homelab-panel}
var_ssh=${var_ssh:-no}
var_pw=${var_pw:-}
var_verbose=${var_verbose:-no}
var_template_storage=${var_template_storage:-}
var_container_storage=${var_container_storage:-}
var_tailscale=${var_tailscale:-}
var_add_key=${var_add_key:-}
var_password_file=${var_password_file:-}
NONINTERACTIVE=${NONINTERACTIVE:-0}
# "Default" or "Advanced", for the summary line.
MODE=Default

# --- Progress messages ------------------------------------------------------------------------
# The coloured lines you see while it works: a spinning "⠋ Doing something" that turns into
# "✔️ Done something", or a red "✖️" if it failed. These are terminal colour codes.

RD=$'\033[01;31m' GN=$'\033[1;92m' YW=$'\033[33m' BL=$'\033[36m' BOLD=$'\033[1m' CL=$'\033[m'
CM="  ✔️  " CROSS="  ✖️  " WARN="  💡  " TAB="  "
STEP_NAME=""
SPINNER_PID=""
# Every time the script creates something on your cluster, it adds the command that would
# remove it to this list. If the install fails, the list is printed, newest first.
CREATED=()

# The little spinning animation next to the current step. It runs in the background until the
# step finishes.
spinner() {
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while :; do
    printf '\r%s%s %s' "$TAB" "${YW}${frames:i++%${#frames}:1}${CL}" "$STEP_NAME"
    sleep 0.1
  done
}
stop_spinner() {
  if [ -n "$SPINNER_PID" ]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
    printf '\r\033[K'
  fi
}
# Starts a step: shows its name with the spinner. Without a terminal (for example when the
# output goes to a log file), or in verbose mode, it prints a plain line instead.
msg_info() {
  stop_spinner
  STEP_NAME=$1
  if [ -t 1 ] && [ "$var_verbose" != yes ]; then
    spinner &
    SPINNER_PID=$!
  else
    printf '%s%s...\n' "$TAB" "$1"
  fi
}
# A step finished (green tick), a warning (yellow), or a failure (red cross).
msg_ok() { stop_spinner; printf '%s%s%s%s\n' "$CM" "$GN" "$1" "$CL"; STEP_NAME=""; }
msg_warn() { stop_spinner; printf '%s%s%s%s\n' "$WARN" "$YW" "$1" "$CL"; }
msg_error() { stop_spinner; printf '%s%s%s%s\n' "$CROSS" "$RD" "$1" "$CL" >&2; }
# Lists what this run has already created on your cluster, newest first, with the command that
# removes each one. Printed whenever the install stops part-way.
print_undo() {
  if [ ${#CREATED[@]} -gt 0 ]; then
    echo "Already created; to undo, newest first:" >&2
    local i
    for ((i = ${#CREATED[@]} - 1; i >= 0; i--)); do echo "  ${CREATED[i]}" >&2; done
  fi
}

# Stop with a message that explains what went wrong, and what to undo.
die() {
  msg_error "$1"
  print_undo
  exit 1
}

# Runs whenever a command fails unexpectedly. It says which step was running, shows the end of
# that command's output if it was hidden (see "run" below), then lists what to undo.
on_error() {
  local code=$? line=$1
  trap - ERR
  msg_error "${STEP_NAME:-install} failed (exit $code at line $line)"
  if [ -s "$RUN_LOG" ]; then
    echo "The last lines it printed:" >&2
    tail -n 15 "$RUN_LOG" | sed 's/^/    /' >&2
  fi
  print_undo
  exit "$code"
}

# Ctrl-C (or the session closing) part-way through: stop, and say what to undo.
on_interrupt() {
  trap - ERR INT TERM
  msg_error "Interrupted during: ${STEP_NAME:-install}"
  print_undo
  exit 130
}

trap 'on_error $LINENO' ERR
trap on_interrupt INT TERM
trap 'stop_spinner; rm -f "$RUN_LOG"' EXIT

# Runs a command quietly, unless you asked for verbose mode. Its output is kept in a temporary
# file, so that if it fails, the end of the output can be shown to explain why.
RUN_LOG=$(mktemp)
run() {
  if [ "$var_verbose" = yes ]; then
    "$@"
    return
  fi
  if "$@" >"$RUN_LOG" 2>&1; then
    : >"$RUN_LOG"
  else
    return $?
  fi
}
# Runs a command inside the new container (Proxmox's "pct exec").
in_ct() { pct exec "$CTID" -- "$@"; }

# --- The question screens -------------------------------------------------------------------
# These use "whiptail", the tool that draws the blue menu boxes in a terminal. Every screen has
# "homelab-panel" across the top.

# The big "homelab-panel" banner at the start.
header_info() {
  [ "$NONINTERACTIVE" = 1 ] || clear 2>/dev/null || true
  cat <<'HEADER'
    __                         __      __                                 __
   / /_  ____  ____ ___  ___  / /___ _/ /_        ____  ____ _____  ___  / /
  / __ \/ __ \/ __ `__ \/ _ \/ / __ `/ __ \______/ __ \/ __ `/ __ \/ _ \/ /
 / / / / /_/ / / / / / /  __/ / /_/ / /_/ /_____/ /_/ / /_/ / / / /  __/ /
/_/ /_/\____/_/ /_/ /_/\___/_/\__,_/_.___/     / .___/\__,_/_/ /_/\___/_/
                                              /_/
HEADER
  echo
}

# Used when you choose Exit or press Cancel on the first screen. Nothing has been changed yet at
# that point, so there is nothing to undo.
exit_script() {
  stop_spinner
  echo -e "${CROSS}${RD}Exited — nothing was changed${CL}"
  exit 0
}

# A Yes/No question. If you already answered it with an environment variable (yes or no), the
# screen is skipped. In unattended mode an unanswered question counts as No.
ask_yesno() {
  case "${3:-}" in
    yes) return 0 ;;
    no) return 1 ;;
  esac
  [ "$NONINTERACTIVE" != 1 ] || return 1
  whiptail --backtitle "$APP" --title "$1" --yesno "$2" 12 70
}

# The password for the panel's sign-in page: typed twice to catch typos, at least 10
# characters. Nothing you type is shown on screen.
ask_password() {
  local a b
  while :; do
    a=$(whiptail --backtitle "$APP" --title "PANEL PASSWORD" --passwordbox \
      "\nThe password for the panel's sign-in page (at least 10 characters):" 10 70 3>&1 1>&2 2>&3) || exit_script
    if [ "${#a}" -lt 10 ]; then
      whiptail --backtitle "$APP" --title "TOO SHORT" --msgbox "At least 10 characters, please." 8 50
      continue
    fi
    b=$(whiptail --backtitle "$APP" --title "PASSWORD VERIFICATION" --passwordbox "\nOnce more:" 10 70 3>&1 1>&2 2>&3) || exit_script
    if [ "$a" = "$b" ]; then
      printf '%s' "$a"
      return
    fi
    whiptail --backtitle "$APP" --title "NO MATCH" --msgbox "Those did not match." 8 50
  done
}

# The first menu: Default Install, Advanced Install, or Exit.
choose_settings() {
  [ "$NONINTERACTIVE" != 1 ] || return 0
  local choice
  choice=$(whiptail --backtitle "$APP" --title "$APP" --ok-button "Select" --cancel-button "Exit Script" --menu \
    "\nChoose an option:\n\nUse Arrow keys to navigate, ENTER to select, TAB for buttons." 16 64 3 \
    "1" "Default Install" "2" "Advanced Install" "3" "Exit" 3>&1 1>&2 2>&3) || exit_script
  case "$choice" in
    1) MODE=Default ;;
    2) MODE=Advanced; advanced_settings ;;
    *) exit_script ;;
  esac
}

# Advanced Install: one screen per setting, in the same order as the community-scripts wizard.
# Each screen shows the current value, so pressing Enter keeps it. Cancel goes back one screen
# (Cancel on the very first screen exits). A screen that doesn't apply, like the gateway when
# you chose DHCP, is skipped, whether you are going forwards or backwards. The last screen shows
# everything you chose and asks you to confirm.
advanced_settings() {
  local step=1 max=20 dir=1 r
  wt() { whiptail --backtitle "$APP [Step $step/$max]" "$@" 3>&1 1>&2 2>&3; }
  back() { step=$((step - 1)); dir=-1; }
  while [ "$step" -le "$max" ]; do
    case $step in
      1) r=$(wt --title "CONTAINER TYPE" --radiolist "\nChoose the container type:" 12 60 2 \
           "1" "Unprivileged (recommended)" ON "0" "Privileged" OFF) || exit_script
         var_unprivileged=${r:-1} ;;
      2) r=$(wt --title "ROOT PASSWORD" --passwordbox "\nRoot password for the CT (blank = console autologin):" 10 60) || { back; continue; }
         var_pw=$r ;;
      3) r=$(wt --title "CONTAINER ID" --inputbox "\nContainer ID:" 10 60 "$CTID") || { back; continue; }
         if ! [[ $r =~ ^[0-9]+$ ]]; then
           whiptail --backtitle "$APP" --title "Invalid ID" --msgbox "Container ID must be numeric." 8 60
           continue
         fi
         if [ "$r" != "$CTID" ] && pct status "$r" >/dev/null 2>&1; then
           whiptail --backtitle "$APP" --title "ID Already In Use" --msgbox "CT $r already exists." 8 60
           continue
         fi
         CTID=$r ;;
      4) r=$(wt --title "HOSTNAME" --inputbox "\nHostname:" 10 60 "$var_hostname") || { back; continue; }
         var_hostname=${r:-$var_hostname} ;;
      5) r=$(wt --title "DISK SIZE" --inputbox "\nDisk size in GB:" 10 60 "$var_disk") || { back; continue; }
         var_disk=${r:-$var_disk} ;;
      6) r=$(wt --title "CPU CORES" --inputbox "\nCPU cores:" 10 60 "$var_cpu") || { back; continue; }
         var_cpu=${r:-$var_cpu} ;;
      7) r=$(wt --title "RAM SIZE" --inputbox "\nRAM in MiB:" 10 60 "$var_ram") || { back; continue; }
         var_ram=${r:-$var_ram} ;;
      8) r=$(wt --title "NETWORK BRIDGE" --inputbox "\nBridge:" 10 60 "$var_brg") || { back; continue; }
         var_brg=${r:-$var_brg} ;;
      9) r=$(wt --title "IPv4 CONFIGURATION" --inputbox "\n'dhcp', or a static address with its prefix (10.0.0.50/24):" 10 70 "$var_net") || { back; continue; }
         var_net=${r:-dhcp} ;;
      10) if [ "$var_net" = dhcp ]; then
            step=$((step + dir)) # no gateway to ask for: pass through, either way
            continue
          fi
          r=$(wt --title "GATEWAY IP" --inputbox "\nGateway:" 10 60 "$var_gateway") || { back; continue; }
          var_gateway=$r ;;
      11) r=$(wt --title "IPv6 CONFIGURATION" --inputbox "\nnone, auto, dhcp or static:" 10 60 "$var_ipv6_method") || { back; continue; }
          var_ipv6_method=${r:-none}
          if [ "$var_ipv6_method" = static ]; then
            var_ipv6_addr=$(wt --title "STATIC IPv6 ADDRESS" --inputbox "\nAddress with its prefix:" 10 60 "$var_ipv6_addr") || continue
            var_ipv6_gw=$(wt --title "IPv6 GATEWAY" --inputbox "\nGateway (blank for none):" 10 60 "$var_ipv6_gw") || continue
          fi ;;
      12) r=$(wt --title "MTU SIZE" --inputbox "\nMTU (blank = default):" 10 60 "$var_mtu") || { back; continue; }
          var_mtu=$r ;;
      13) r=$(wt --title "DNS SEARCH DOMAIN" --inputbox "\nSearch domain (blank = the node's):" 10 60 "$var_searchdomain") || { back; continue; }
          var_searchdomain=$r ;;
      14) r=$(wt --title "DNS SERVER" --inputbox "\nNameserver:" 10 60 "$var_ns") || { back; continue; }
          var_ns=${r:-$var_ns} ;;
      15) r=$(wt --title "MAC ADDRESS" --inputbox "\nMAC address (blank = random):" 10 60 "$var_mac") || { back; continue; }
          var_mac=$r ;;
      16) r=$(wt --title "VLAN TAG" --inputbox "\nVLAN tag (blank = none):" 10 60 "$var_vlan") || { back; continue; }
          var_vlan=$r ;;
      17) r=$(wt --title "CONTAINER TAGS" --inputbox "\nTags, separated by ';':" 10 60 "$var_tags") || { back; continue; }
          var_tags=$r ;;
      18) if wt --defaultno --title "SSH ACCESS" --yesno "\nEnable root SSH into the CT?" 10 60; then var_ssh=yes; else var_ssh=no; fi ;;
      19) if wt --defaultno --title "VERBOSE MODE" --yesno "\nShow every command's output?" 10 60; then var_verbose=yes; else var_verbose=no; fi ;;
      20) summary_text
          wt --title "CONFIRM SETTINGS" --yesno "\n$SUMMARY\n\nCreate the CT with these settings?" 24 72 || { back; continue; } ;;
    esac
    # An answered screen always moves on; `dir` only steers a skipped one.
    step=$((step + 1))
    dir=1
  done
}

# The questions that are about the panel rather than the container. Both installs ask them.
ask_panel_questions() {
  if ask_yesno "TAILSCALE" "\nInstall Tailscale in the CT, so the panel is reachable at http://$var_hostname:8420 on your tailnet?" "$var_tailscale"; then
    var_tailscale=yes
  else
    var_tailscale=no
  fi
  if ask_yesno "SSH KEY ON THE NODES" "\nAdd the panel's SSH key to /etc/pve/priv/authorized_keys?\n\nThis lets the panel log in as root on every node, which it needs to run upgrades and move files." "$var_add_key"; then
    var_add_key=yes
  else
    var_add_key=no
  fi
}

# The list of chosen settings, shown on the confirm screen and printed before the install starts.
summary_text() {
  local type=Unprivileged
  [ "$var_unprivileged" = 1 ] || type=Privileged
  SUMMARY="🆔  Container ID: $CTID
🖥️  Operating System: Debian 13
📦  Container Type: $type
💾  Disk Size: ${var_disk} GB
🧠  CPU Cores: $var_cpu
🛠️  RAM Size: ${var_ram} MiB
🏠  Hostname: $var_hostname
🌉  Bridge: $var_brg
📡  IPv4: $var_net
🔍  DNS: $var_ns
🔗  Tailscale: ${var_tailscale:-asked next}"
}

show_summary() {
  summary_text
  echo -e "${BOLD}${BL}Using ${MODE} Settings on node ${NODE}${CL}"
  printf '%s\n' "$SUMMARY" | sed "s/^/$TAB/"
  echo -e "${BOLD}${GN}Creating a homelab-panel LXC with the settings above${CL}"
  echo
}

# --- The install steps ------------------------------------------------------------------------

# Checks before anything happens: a proper release copy of this script, running as root on a
# Proxmox node, a free container ID, and a DNS server for the container.
preflight() {
  [ "$VERSION" != dev ] || die "this install.sh is unstamped; run the one attached to a release"
  [ "$(id -u)" = 0 ] || die "run as root on a Proxmox node"
  if ! command -v pct >/dev/null || ! command -v pveum >/dev/null; then
    die "pct/pveum not found: is this a Proxmox node?"
  fi
  if [ "$NONINTERACTIVE" = 1 ] && [ ! -s "$var_password_file" ]; then
    die "NONINTERACTIVE=1 needs var_password_file: a file holding the panel's sign-in password"
  fi
  NODE=$(hostname)
  CTID=${var_ctid:-$(pvesh get /cluster/nextid)}
  [ -n "$CTID" ] || die "could not get a free CT id; set var_ctid"
  if pct status "$CTID" >/dev/null 2>&1; then die "CT $CTID already exists"; fi
  # A token called "panel" for panel@pve means an earlier install (or another panel) is still
  # there. Its secret can't be read back, so the panel can't share it, and replacing it would
  # cut off the other panel. Better to say so now, before anything is created.
  if pveum user token list panel@pve --output-format json 2>/dev/null | grep -q '"tokenid":"panel"'; then
    die "panel@pve already has an API token named \"panel\", from an earlier install. If that install is gone, remove it with: pveum user token remove panel@pve panel"
  fi
  # The container gets its DNS server set explicitly. Left alone, a new container copies the
  # node's settings, and if the node runs Tailscale that can be Tailscale's own 100.100.100.100,
  # which doesn't work inside the container and makes package downloads fail. So the script
  # uses the node's first other DNS server, or 1.1.1.1 if there is none.
  if [ -z "$var_ns" ]; then
    var_ns=$(awk '$1 == "nameserver" && $2 != "100.100.100.100" { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)
  fi
  var_ns=${var_ns:-1.1.1.1}
}

# Picks a Proxmox storage that can hold either container disks ("rootdir") or templates
# ("vztmpl"). If your node has only one, it is used without asking.
pick_storage() {
  local list n
  list=$(pvesm status -content "$1" | awk 'NR > 1 { print $1 }')
  n=$(printf '%s\n' "$list" | grep -c . || true)
  [ "$n" -gt 0 ] || die "no storage on $NODE can hold $1"
  if [ "$n" -eq 1 ] || [ "$NONINTERACTIVE" = 1 ]; then
    printf '%s\n' "$list" | head -n1
    return
  fi
  local items=() s
  while read -r s; do items+=("$s" " "); done <<<"$list"
  # Cancel here returns 10, so the caller can tell "you chose to stop" from a real error.
  whiptail --backtitle "$APP" --title "$2" --menu "\nWhere should it go?" 16 58 6 "${items[@]}" 3>&1 1>&2 2>&3 || exit 10
}

# After pick_storage stopped: Cancel (10) exits quietly, anything else was an error, which
# pick_storage has already explained.
storage_cancelled() {
  local code=$?
  [ "$code" != 10 ] || exit_script
  exit "$code"
}

# Downloads the panel and its files from this script's release, into a temporary folder on the
# node, and checks every file against its published SHA-256 checksum. This happens before
# anything is created, so a broken or tampered download stops the install with nothing to undo.
fetch_release() {
  msg_info "Downloading release $VERSION"
  DL=$(mktemp -d)
  local f
  for f in "$ASSET" homelab-panel.service update.sh panel.env.example THIRD-PARTY-NOTICES; do
    curl -fsSL --proto '=https' -o "$DL/$f" "$RELEASE_BASE/$f"
    curl -fsSL --proto '=https' -o "$DL/$f.sha256" "$RELEASE_BASE/$f.sha256"
    (cd "$DL" && sha256sum -c --quiet "$f.sha256" >/dev/null 2>&1) || die "$f does not match its checksum; not installing"
  done
  msg_ok "Downloaded release $VERSION"
}

# Builds the container's network setting in the form Proxmox expects, for example
# "name=eth0,bridge=vmbr0,ip=dhcp", from the network answers.
net0() {
  local n="name=eth0,bridge=$var_brg"
  if [ "$var_net" = dhcp ]; then
    n+=",ip=dhcp"
  else
    n+=",ip=$var_net"
    [ -z "$var_gateway" ] || n+=",gw=$var_gateway"
  fi
  case "$var_ipv6_method" in
    auto) n+=",ip6=auto" ;;
    dhcp) n+=",ip6=dhcp" ;;
    static)
      n+=",ip6=$var_ipv6_addr"
      [ -z "$var_ipv6_gw" ] || n+=",gw6=$var_ipv6_gw"
      ;;
  esac
  [ -z "$var_mac" ] || n+=",hwaddr=$var_mac"
  [ -z "$var_vlan" ] || n+=",tag=$var_vlan"
  [ -z "$var_mtu" ] || n+=",mtu=$var_mtu"
  printf '%s' "$n"
}

# Downloads the Debian 13 template if the node doesn't have it, creates the container, and
# waits until it can reach the internet.
create_ct() {
  msg_info "Downloading the Debian 13 template"
  run pveam update
  local tmpl
  tmpl=$(pveam available --section system | awk '$2 ~ /^debian-13-standard_/ { print $2 }' | sort -V | tail -n1)
  [ -n "$tmpl" ] || die "no debian-13-standard template in pveam available"
  pveam list "$var_template_storage" | grep -q "$tmpl" || run pveam download "$var_template_storage" "$tmpl"
  msg_ok "Debian 13 template ready"

  msg_info "Creating LXC Container"
  # "nesting=1" lets programs inside the container use some Linux isolation features. The panel's
  # service uses them to fence itself off (see homelab-panel.service), so it needs this on.
  local opts=(--hostname "$var_hostname" --unprivileged "$var_unprivileged" --features nesting=1
    --cores "$var_cpu" --memory "$var_ram" --swap 0 --rootfs "$var_container_storage:$var_disk"
    --net0 "$(net0)" --nameserver "$var_ns" --onboot 1 --tags "$var_tags")
  [ -z "$var_searchdomain" ] || opts+=(--searchdomain "$var_searchdomain")
  pct create "$CTID" "$var_template_storage:vztmpl/$tmpl" "${opts[@]}" >/dev/null
  CREATED+=("pct stop $CTID; pct destroy $CTID")
  if [ "$var_tailscale" = yes ]; then
    # Tailscale needs the network tunnel device (/dev/net/tun), which containers don't get by
    # default. These two lines in the container's settings give it access. They have to be
    # there before the container first starts.
    printf '%s\n' 'lxc.cgroup2.devices.allow: c 10:200 rwm' \
      'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >>"$PVE_LXC_DIR/$CTID.conf"
  fi
  pct start "$CTID"
  msg_ok "Created LXC Container $CTID"

  msg_info "Waiting for the network"
  local i=0
  until in_ct getent hosts deb.debian.org >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 60 ] || die "CT $CTID has no working DNS after 60 s"
    sleep 1
  done
  msg_ok "Network is up"
}

# How you log in to the container itself from the Proxmox console: with the root password you
# chose, or automatically if you left it blank (as community-scripts containers do).
ct_access() {
  msg_info "Setting up console access"
  if [ -n "$var_pw" ]; then
    # The password is passed in through a pipe rather than typed into the command itself,
    # because a command's text can be seen by anyone on the node while it runs.
    printf 'root:%s\n' "$var_pw" | pct exec "$CTID" -- chpasswd
  else
    # No root password: console autologin, as community-scripts does.
    # shellcheck disable=SC2016 # $TERM is for the getty unit, not this shell
    in_ct sh -eu -c 'mkdir -p /etc/systemd/system/container-getty@1.service.d
      printf "[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%%I 115200,38400,9600 \$TERM\n" \
        > /etc/systemd/system/container-getty@1.service.d/override.conf'
  fi
  msg_ok "Console access set"
}

# The few programs the panel needs inside the container: the SSH client (to reach your nodes),
# rsync (for file transfers), security certificates, and curl (for updates). Plus the SSH
# server, if you asked for root SSH into the container.
install_packages() {
  msg_info "Installing dependencies"
  local pkgs="openssh-client rsync ca-certificates curl"
  [ "$var_ssh" != yes ] || pkgs="$pkgs openssh-server"
  run in_ct sh -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y --no-install-recommends $pkgs"
  if [ "$var_ssh" = yes ]; then
    # Without a root password, root can log in over SSH with a key only, never a password.
    local how=prohibit-password
    [ -z "$var_pw" ] || how=yes
    in_ct sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin $how/" /etc/ssh/sshd_config
  fi
  msg_ok "Installed dependencies"
}

# Creates the panel's own user and folders inside the container, and puts its files in place:
#   /opt/homelab-panel/                      the program and its third-party license notices
#   /etc/homelab-panel/.env                  settings (see panel.env.example)
#   /etc/systemd/system/homelab-panel.service how the system runs it
#   /usr/local/bin/homelab-panel-update      the update helper
#   /var/lib/homelab-panel/                  the panel's data: its database and job logs
layout() {
  msg_info "Installing homelab-panel $VERSION"
  in_ct sh -eu -c '
    useradd --system --home-dir /var/lib/homelab-panel --shell /usr/sbin/nologin homelab-panel
    install -d -m 0755 -o root -g root /opt/homelab-panel
    install -d -m 0750 -o root -g homelab-panel /etc/homelab-panel
    install -d -m 0700 -o homelab-panel -g homelab-panel /etc/homelab-panel/ssh /var/lib/homelab-panel
    install -d -m 0700 -o homelab-panel -g homelab-panel /var/lib/homelab-panel/.ssh
  '
  pct push "$CTID" "$DL/$ASSET" /opt/homelab-panel/homelab-panel --perms 0755
  pct push "$CTID" "$DL/THIRD-PARTY-NOTICES" /opt/homelab-panel/THIRD-PARTY-NOTICES --perms 0644
  pct push "$CTID" "$DL/homelab-panel.service" /etc/systemd/system/homelab-panel.service
  pct push "$CTID" "$DL/update.sh" /usr/local/bin/homelab-panel-update --perms 0755
  pct push "$CTID" "$DL/panel.env.example" /etc/homelab-panel/.env --perms 0640 --group homelab-panel
  # Tell the panel which container it lives in. When you upgrade several things at once it then
  # does its own container and node last, and it warns you before restarting either.
  in_ct sed -i "s/^PANEL_SELF_CTID=.*/PANEL_SELF_CTID=$CTID/" /etc/homelab-panel/.env
  msg_ok "Installed homelab-panel $VERSION"
}

# Creates the Proxmox API access the panel uses to see your cluster and run snapshots and
# reboots: a user "panel@pve", a role "PanelRole" allowing only those things, and an API token.
# The token is "privilege-separated", meaning it gets its permissions on its own rather than
# borrowing everything the user could do.
api_token() {
  msg_info "Creating the API user, role and token"
  local privs="Sys.Audit,Sys.Modify,VM.Audit,VM.PowerMgmt,VM.Snapshot,VM.GuestAgent.Unrestricted,Datastore.Audit"
  # The user and the role are reused if they already exist (an earlier install made them), and
  # only the ones this run creates go in the undo list.
  if pveum role list --output-format json | grep -q '"roleid":"PanelRole"'; then
    pveum role modify PanelRole --privs "$privs"
  else
    pveum role add PanelRole --privs "$privs"
    CREATED+=("pveum role delete PanelRole")
  fi
  if ! pveum user list --output-format json | grep -q '"userid":"panel@pve"'; then
    pveum user add panel@pve --comment homelab-panel
    CREATED+=("pveum user delete panel@pve")
  fi
  pveum acl modify / --users panel@pve --roles PanelRole
  local secret tmp
  secret=$(pveum user token add panel@pve panel --privsep 1 --output-format json \
    | perl -MJSON::PP -0e 'print decode_json(<STDIN>)->{value}')
  pveum acl modify / --tokens 'panel@pve!panel' --roles PanelRole
  # The token's secret goes into the container through a temporary file, never on a command
  # line (where anyone on the node could see it), and is written into the settings file there.
  tmp=$(mktemp)
  printf '%s' "$secret" >"$tmp"
  pct push "$CTID" "$tmp" /root/.panel-token --perms 0600
  rm -f "$tmp"
  # shellcheck disable=SC2016 # the script runs in the CT's shell
  in_ct sh -eu -c '
    f=/etc/homelab-panel/.env
    s=$(cat /root/.panel-token); rm -f /root/.panel-token
    sed -i "s/^PVE_TOKEN_ID=.*/PVE_TOKEN_ID=panel@pve!panel/; /^PVE_TOKEN_SECRET=/d" "$f"
    printf "PVE_TOKEN_SECRET=%s\n" "$s" >> "$f"
  '
  msg_ok "Created the API token"
}

# Writes the panel's list of nodes (hosts.yaml) from your cluster's own list, with each node's
# cluster network address. The panel never stores your guests or storage here; it reads those
# live from Proxmox. The "denylist" is folders the file manager will never show.
hosts_file() {
  msg_info "Writing hosts.yaml"
  local tmp
  tmp=$(mktemp)
  pvesh get /cluster/status --output-format json | perl -MJSON::PP -0e '
    print "# Written by install.sh. Only connection info lives here.\nhosts:\n";
    for my $n (sort { $a->{name} cmp $b->{name} } grep { $_->{type} eq "node" } @{ decode_json(<STDIN>) }) {
      print "  $n->{name}: { kind: pve-node, address: $n->{ip}, lan: $n->{ip}, user: root }\n";
    }
    print "\nfiles:\n  denylist: [/, /boot, /dev, /proc, /sys, /run, /etc/pve, /etc/ssh, /root/.ssh]\n";
  ' >"$tmp"
  pct push "$CTID" "$tmp" /etc/homelab-panel/hosts.yaml --perms 0640 --group homelab-panel
  rm -f "$tmp"
  msg_ok "Wrote hosts.yaml"
}

# Gives the panel its own SSH key. The key is made inside the container, so its private half
# never leaves it. For the panel to log in to your nodes, its public key has to be added to
# Proxmox's shared list of allowed keys. That gives the panel root access to every node, which it
# needs to run upgrades and move files, so the script only does it if you said yes.
ssh_key() {
  msg_info "Creating the panel's SSH key"
  in_ct su -s /bin/sh homelab-panel -c "ssh-keygen -q -t ed25519 -N '' -f /etc/homelab-panel/ssh/id_ed25519 -C homelab-panel-ct$CTID"
  local pub tmp
  pub=$(in_ct cat /etc/homelab-panel/ssh/id_ed25519.pub)
  # Each node's own "host key" (its SSH fingerprint) is copied from Proxmox into the
  # container, so the panel can check it is talking to your real nodes from the very first
  # connection.
  tmp=$(mktemp)
  pvesh get /cluster/status --output-format json | perl -MJSON::PP -0e '
    for my $n (grep { $_->{type} eq "node" } @{ decode_json(<STDIN>) }) {
      open my $f, "<", "/etc/pve/nodes/$n->{name}/ssh_known_hosts" or next;
      while (<$f>) { s/^\S+/$n->{ip}/; print }
    }
  ' >"$tmp"
  pct push "$CTID" "$tmp" /var/lib/homelab-panel/.ssh/known_hosts --perms 0644 --user homelab-panel --group homelab-panel
  rm -f "$tmp"
  if [ "$var_add_key" = yes ]; then
    printf '%s\n' "$pub" >>/etc/pve/priv/authorized_keys
    CREATED+=("sed -i '/homelab-panel-ct$CTID\$/d' /etc/pve/priv/authorized_keys")
    msg_ok "Added the panel's SSH key to the nodes"
  else
    msg_ok "Created the panel's SSH key"
    msg_warn "Add this line to /etc/pve/priv/authorized_keys before using the panel: $pub"
  fi
}

# Installs Tailscale from Tailscale's own package repository and starts it. Tailscale prints a
# link: open it and approve the device, and the panel joins your tailnet under its hostname.
tailscale_setup() {
  [ "$var_tailscale" = yes ] || return 0
  msg_info "Installing Tailscale"
  run in_ct sh -eu -c '
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    printf "Types: deb\nURIs: https://pkgs.tailscale.com/stable/debian\nSuites: trixie\nComponents: main\nSigned-By: /usr/share/keyrings/tailscale-archive-keyring.gpg\n" \
      > /etc/apt/sources.list.d/tailscale.sources
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -qq -y tailscale'
  CREATED+=("remove $var_hostname on https://login.tailscale.com/admin/machines")
  msg_ok "Installed Tailscale"
  echo
  echo "${BOLD}Log the panel into your tailnet:${CL} open the link below. Waiting up to 10 minutes."
  # "--accept-dns=false" keeps the container's DNS settings as they are. Otherwise Tailscale would
  # switch the container to its own DNS, which can stop package downloads from working.
  if ! pct exec "$CTID" -- tailscale up --hostname="$var_hostname" --accept-dns=false --timeout=10m; then
    msg_warn "Not logged in yet. Later: pct exec $CTID -- tailscale up --hostname=$var_hostname --accept-dns=false"
  fi
}

# Sets the password for the panel's sign-in page. Only a scrambled version (a hash) is stored,
# never the password itself.
panel_password() {
  local pw
  if [ "$NONINTERACTIVE" = 1 ]; then
    pw=$(head -n1 "$var_password_file")
  else
    pw=$(ask_password)
  fi
  msg_info "Setting the panel's password"
  # The password is passed through a pipe, never on a command line, and set as the panel's own
  # user so the panel can read the file it ends up in.
  printf '%s\n' "$pw" | pct exec "$CTID" -- su -s /bin/sh homelab-panel -c \
    'PANEL_DATA_DIR=/var/lib/homelab-panel /opt/homelab-panel/homelab-panel set-password --stdin' >/dev/null
  msg_ok "Set the panel's password"
}

# Starts the panel, waits until it answers, and prints the address to open in your browser.
start() {
  msg_info "Starting homelab-panel"
  in_ct systemctl daemon-reload
  in_ct systemctl enable --now homelab-panel >/dev/null 2>&1
  local i=0
  until in_ct curl -fsS -o /dev/null http://127.0.0.1:8420/api/health; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || die "no answer on /api/health after 30 s: pct exec $CTID -- journalctl -u homelab-panel -n 50"
    sleep 1
  done
  local ip
  ip=$(in_ct hostname -I | awk '{ print $1 }')
  rm -rf "$DL"
  msg_ok "homelab-panel is running"
  echo "${TAB}LAN:       ${BL}http://${ip:-<ct-ip>}:8420${CL}"
  [ "$var_tailscale" != yes ] || echo "${TAB}Tailscale: ${BL}http://$var_hostname:8420${CL}"
  echo "${TAB}Update:    pct exec $CTID -- homelab-panel-update"
}

# The whole install, in order. Everything that only asks questions comes first; nothing on your
# cluster changes until fetch_release has downloaded and checked every file.
main() {
  header_info
  preflight
  choose_settings
  [ -n "$var_template_storage" ] || var_template_storage=$(pick_storage vztmpl "TEMPLATE STORAGE") || storage_cancelled
  [ -n "$var_container_storage" ] || var_container_storage=$(pick_storage rootdir "CONTAINER STORAGE") || storage_cancelled
  ask_panel_questions
  show_summary
  fetch_release
  create_ct
  ct_access
  install_packages
  layout
  api_token
  hosts_file
  ssh_key
  tailscale_setup
  panel_password
  start
}

main "$@"
