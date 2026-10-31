#!/usr/bin/env bash
# =============================================================================
#  OldBox — turn any old laptop or mini-PC into a rock-solid home server.
#
#  One command gives you: a hardened headless Linux box, Docker, a ready-to-run
#  stack (PostgreSQL, Redis, MariaDB, MongoDB, Caddy, Uptime Kuma, Dozzle,
#  Adminer, phpMyAdmin, PHP), Telegram-bot templates, private remote access
#  (Tailscale), public access options (Cloudflare Tunnel / Tailscale Funnel /
#  direct), nightly backups, disk-health monitoring and laptop-specific tuning.
#
#  Design goals
#    * Safe to re-run      every step checks state first; nothing is duplicated
#    * Never destructive   your edits are kept (new versions land in *.new)
#    * Lock-out proof      SSH password login is only disabled if a key exists,
#                          config is validated before it is applied, and the
#                          firewall always allows your real SSH port first
#    * Works everywhere    Debian/Ubuntu, Fedora/RHEL, Arch and openSUSE families
#    * Pleasant to use     adaptive colours, spinner, progress bar, ASCII
#                          fallback, any terminal width, non-interactive mode
#
#  Usage     sudo ./oldbox.sh [command] [options]      (see --help)
#  Commands  install (default) | check | status | update | backup | help
#
#  SPDX-License-Identifier: MIT
# =============================================================================
# shellcheck disable=SC1091,SC2034,SC2155

# --- bootstrap guard (must stay POSIX so old shells print a clean message) ----
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'oldbox: this script needs bash. Try:  bash %s\n' "$0" >&2
  exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf 'oldbox: bash 4 or newer is required (found %s).\n' "$BASH_VERSION" >&2
  exit 1
fi

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 022
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

# =============================================================================
# 1. Constants, defaults and global state
# =============================================================================
readonly OLDBOX_VERSION="1.0.0"
readonly PROG="oldbox"
SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
START_SECONDS=$SECONDS
ORIG_ARGS=("$@")

LOG_FILE="${OLDBOX_LOG:-/var/log/oldbox.log}"
STATE_DIR="/var/lib/oldbox"
ANSWERS_FILE="$STATE_DIR/answers.env"
STATE_FILE="$STATE_DIR/state.env"
CONF_DIR="/etc/oldbox"
LOCK_FILE="/run/oldbox.lock"
TMP_DIR=""

COMMAND="install"
ASSUME_YES=0 DRY_RUN=0 FORCE_NO_COLOR=0 FORCE_NO_ANIM=0 FORCE_ASCII=0
STARTED=0 HAVE_TTY=0 HAVE_SYSTEMD=0 PF_FAIL=0 RUN_OPT=0 DOCKER_RESTART=0
WARNINGS=() STEPS=()
STEP_N=0 STEP_TOTAL=0
declare -A EXPLICIT=()

# Everything the user can toggle. Order = order shown in the interactive menu.
COMP_IDS=(postgres redis mariadb mongo caddy kuma dozzle adminer phpmyadmin php
          tailscale cockpit backups smart templates power battery ssd updates
          firewall ssh)

declare -A COMP_DESC=(
  [postgres]="PostgreSQL        database (recommended default)"
  [redis]="Redis             cache, queues, bot state"
  [mariadb]="MariaDB           MySQL-compatible database"
  [mongo]="MongoDB           document database (needs an AVX CPU)"
  [caddy]="Caddy             reverse proxy + automatic HTTPS"
  [kuma]="Uptime Kuma      uptime alerts (Telegram, email, ...)"
  [dozzle]="Dozzle            live container logs in a browser"
  [adminer]="Adminer           web UI for PostgreSQL / MySQL"
  [phpmyadmin]="phpMyAdmin        web UI for MariaDB / MySQL"
  [php]="PHP-FPM + sites   PHP runtime served through Caddy"
  [tailscale]="Tailscale         private VPN: reach the box from anywhere"
  [cockpit]="Cockpit           browser dashboard for the OS"
  [backups]="Nightly backups   DB dumps + configs (systemd timer)"
  [smart]="Disk health       smartd monitoring"
  [templates]="Bot templates    Python + Node Telegram starters"
  [power]="Always-on mode    ignore lid close, never sleep"
  [battery]="Battery limit     cap charge level (if supported)"
  [ssd]="SSD care          TRIM, low swappiness, capped logs"
  [updates]="Auto security     unattended security updates"
  [firewall]="Firewall          deny-by-default, SSH rate-limited"
  [ssh]="SSH hardening     key-only login (only if a key exists)"
)

declare -A COMP_DEF=(
  [postgres]=yes [redis]=yes [mariadb]=no [mongo]=no [caddy]=yes [kuma]=yes
  [dozzle]=yes [adminer]=no [phpmyadmin]=no [php]=no [tailscale]=yes
  [cockpit]=no [backups]=yes [smart]=yes [templates]=yes [power]=yes
  [battery]=yes [ssd]=yes [updates]=yes [firewall]=yes [ssh]=yes
)

# Values remembered between runs (never secrets).
ANSWER_KEYS=(ADMIN_USER TIMEZONE STACK_DIR TUNNEL_MODE DOMAIN ACME_EMAIL
             GITHUB_KEYS_USER BATTERY_LIMIT SWAPPINESS JOURNAL_MAX
             BACKUP_KEEP_DAYS BACKUP_TIME BACKUP_REMOTE ADMIN_BIND
             WEB_HTTP_PORT DO_UPGRADE)
for _id in "${COMP_IDS[@]}"; do ANSWER_KEYS+=("WITH_${_id^^}"); done
unset _id

# =============================================================================
# 2. UI toolkit: colours, symbols, width, spinner, banner
# =============================================================================
IS_TTY=0 ANIMATE=0 UNICODE=0 COLOR_MODE=none W=80
C_RESET='' C_BOLD='' C_DIM='' C_ACCENT='' C_ACCENT2='' C_OK='' C_WARN=''
C_ERR='' C_INFO='' C_MUTED=''
S_OK='+' S_WARN='!' S_ERR='x' S_INFO='i' S_DOT='*' S_RULE='-' S_RAIL='|'
S_BAR_ON='#' S_BAR_OFF='.' S_ELL='~' S_ARROW='>' S_CHECK='[x]' S_UNCHECK='[ ]'
# shellcheck disable=SC1003
SPIN=('-' '\' '|' '/')

term_width() {
  local w
  w=$(tput cols 2>/dev/null || true)
  [[ $w =~ ^[0-9]+$ ]] || w=${COLUMNS:-80}
  [[ $w =~ ^[0-9]+$ ]] || w=80
  if (( w < 40 )); then w=40; fi
  if (( w > 100 )); then w=100; fi
  printf '%s' "$w"
}

ui_init() {
  if [[ -t 1 ]]; then IS_TTY=1; else IS_TTY=0; fi
  COLOR_MODE=none
  if (( IS_TTY && ! FORCE_NO_COLOR )) && [[ -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    if [[ ${COLORTERM:-} == *truecolor* || ${COLORTERM:-} == *24bit* ]]; then
      COLOR_MODE=true
    else
      local n
      n=$(tput colors 2>/dev/null || echo 8)
      [[ $n =~ ^[0-9]+$ ]] || n=8
      if (( n >= 256 )); then COLOR_MODE=256; else COLOR_MODE=8; fi
    fi
  fi
  ANIMATE=0
  if (( IS_TTY && ! FORCE_NO_ANIM )) && [[ ${TERM:-dumb} != dumb ]]; then ANIMATE=1; fi

  UNICODE=0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UNICODE=1 ;;
  esac
  if (( FORCE_ASCII )) || [[ ${TERM:-} == linux ]]; then UNICODE=0; fi

  if [[ $COLOR_MODE != none ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    case $COLOR_MODE in
      true)
        C_ACCENT=$'\033[38;2;0;200;255m'  C_ACCENT2=$'\033[38;2;190;120;255m'
        C_OK=$'\033[38;2;80;250;123m'     C_WARN=$'\033[38;2;255;200;80m'
        C_ERR=$'\033[38;2;255;85;85m'     C_INFO=$'\033[38;2;120;170;255m'
        C_MUTED=$'\033[38;2;130;140;160m' ;;
      256)
        C_ACCENT=$'\033[38;5;45m'  C_ACCENT2=$'\033[38;5;177m' C_OK=$'\033[38;5;84m'
        C_WARN=$'\033[38;5;221m'   C_ERR=$'\033[38;5;203m'     C_INFO=$'\033[38;5;111m'
        C_MUTED=$'\033[38;5;245m' ;;
      *)
        C_ACCENT=$'\033[36m' C_ACCENT2=$'\033[35m' C_OK=$'\033[32m' C_WARN=$'\033[33m'
        C_ERR=$'\033[31m'    C_INFO=$'\033[34m'    C_MUTED=$'\033[90m' ;;
    esac
  fi

  if (( UNICODE )); then
    S_OK='✔' S_WARN='⚠' S_ERR='✖' S_INFO='ℹ' S_DOT='•' S_RULE='─' S_RAIL='┃'
    S_BAR_ON='█' S_BAR_OFF='░' S_ELL='…' S_ARROW='›' S_CHECK='[✔]' S_UNCHECK='[ ]'
    SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  fi
  W=$(term_width)
  trap 'W=$(term_width)' WINCH
}

trunc() { # trunc "text" max
  local s=$1 n=$2
  if (( n < 8 )); then n=8; fi
  if (( ${#s} > n )); then printf '%s%s' "${s:0:n-1}" "$S_ELL"; else printf '%s' "$s"; fi
}

hr() {
  local s
  printf -v s '%*s' "$((W - 4))" ''
  printf '  %s%s%s\n' "$C_MUTED" "${s// /$S_RULE}" "$C_RESET"
}

# emit SYMBOL COLOR text...  — wraps to the terminal width, indents continuations
emit() {
  local sym=$1 col=$2 first=1 line
  shift 2
  while IFS= read -r line; do
    if (( first )); then
      printf '  %s%s%s %s\n' "$col" "$sym" "$C_RESET" "$line"; first=0
    else
      printf '    %s\n' "$line"
    fi
  done < <(printf '%s\n' "$*" | fold -s -w $((W - 6)))
}

# rail COLOR text... — text with a coloured left rail (used for summaries)
rail() {
  local col=$1 line
  shift
  while IFS= read -r line; do
    printf '  %s%s%s %s\n' "$col" "$S_RAIL" "$C_RESET" "$line"
  done < <(printf '%s\n' "$*" | fold -s -w $((W - 6)))
}

# rail_kv COLOR "Label" "value" — aligned label/value inside a rail
rail_kv() {
  local col=$1 label=$2 value=$3 pad=15 line first=1
  while IFS= read -r line; do
    if (( first )); then
      printf '  %s%s%s %s%-*s%s %s\n' "$col" "$S_RAIL" "$C_RESET" "$C_MUTED" "$pad" "$label" "$C_RESET" "$line"; first=0
    else
      printf '  %s%s%s %*s %s\n' "$col" "$S_RAIL" "$C_RESET" "$pad" "" "$line"
    fi
  done < <(printf '%s\n' "$value" | fold -s -w $(( W - pad - 8 )))
}

log_raw() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
msg_ok()   { emit "$S_OK"   "$C_OK"   "$*"; log_raw "OK    $*"; }
msg_info() { emit "$S_INFO" "$C_INFO" "$*"; log_raw "INFO  $*"; }
msg_dim()  { emit "$S_DOT"  "$C_MUTED" "$*"; log_raw "NOTE  $*"; }
msg_err()  { emit "$S_ERR"  "$C_ERR"  "$*"; log_raw "ERROR $*"; }
msg_warn() { emit "$S_WARN" "$C_WARN" "$*"; WARNINGS+=("$*"); log_raw "WARN  $*"; }

section() { printf '\n  %s%s%s\n' "$C_BOLD$C_ACCENT" "$1" "$C_RESET"; hr; }

progress_bar() { # progress_bar done total width
  local d=$1 t=$2 w=$3 f i out=''
  f=$(( t > 0 ? d * w / t : 0 ))
  for (( i = 0; i < w; i++ )); do
    if (( i < f )); then out+="${C_ACCENT}${S_BAR_ON}"; else out+="${C_MUTED}${S_BAR_OFF}"; fi
  done
  printf '%s%s' "$out" "$C_RESET"
}

step() { # step "Title"  — prints "› ████░░░░ 3/12  Title"
  STEP_N=$((STEP_N + 1))
  local bw=$(( W < 60 ? 12 : 24 ))
  printf '\n%s%s%s %s %s%d/%d%s  %s%s%s\n' \
    "$C_ACCENT2" "$S_ARROW" "$C_RESET" "$(progress_bar "$STEP_N" "$STEP_TOTAL" "$bw")" \
    "$C_MUTED" "$STEP_N" "$STEP_TOTAL" "$C_RESET" \
    "$C_BOLD" "$(trunc "$1" $((W - bw - 14)))" "$C_RESET"
  log_raw "STEP $STEP_N/$STEP_TOTAL $1"
}

_banner_rows() {
  local -a O=(' ### ' '#   #' '#   #' '#   #' ' ### ')
  local -a L=('#    ' '#    ' '#    ' '#    ' '#####')
  local -a D=('#### ' '#   #' '#   #' '#   #' '#### ')
  local -a B=('#### ' '#   #' '#### ' '#   #' '#### ')
  local -a X=('#   #' ' # # ' '  #  ' ' # # ' '#   #')
  local i
  for i in 0 1 2 3 4; do
    printf '%s  %s  %s  %s  %s  %s\n' "${O[i]}" "${L[i]}" "${D[i]}" "${B[i]}" "${O[i]}" "${X[i]}"
  done
}

_gradient_line() { # _gradient_line "text" row
  local text=$1 row=$2 i ch r g b len=${#1}
  case $COLOR_MODE in
    true)
      for (( i = 0; i < len; i++ )); do
        ch=${text:i:1}
        if [[ $ch == ' ' ]]; then printf ' '; continue; fi
        r=$(( (i * 190 / 40) + row * 4 )); g=$(( 200 - (i * 90 / 40) )); b=255
        printf '\033[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "$ch"
      done
      printf '%s' "$C_RESET" ;;
    256)
      local -a pal=(51 45 39 75 111 141)
      printf '\033[38;5;%dm%s%s' "${pal[row]}" "$text" "$C_RESET" ;;
    *) printf '%s%s%s' "$C_ACCENT" "$text" "$C_RESET" ;;
  esac
}

banner() {
  printf '\n'
  if (( W >= 48 )); then
    local -a rows
    local r line
    mapfile -t rows < <(_banner_rows)
    for r in 0 1 2 3 4; do
      line=${rows[r]}
      if (( UNICODE )); then line=${line//#/█}; fi
      printf '  '; _gradient_line "$line" "$r"; printf '\n'
    done
  else
    printf '  %s%sOLDBOX%s\n' "$C_BOLD" "$C_ACCENT" "$C_RESET"
  fi
  printf '  %s%s%s\n' "$C_MUTED" "$(trunc "Turn any old laptop into a rock-solid home server  v${OLDBOX_VERSION}" $((W - 4)))" "$C_RESET"
}

kv() { printf '  %s%-13s%s %s\n' "$C_MUTED" "$1" "$C_RESET" "$2"; }

# =============================================================================
# 3. Errors, cleanup, command runner with spinner, retry
# =============================================================================
stop_cursor_hidden() { if (( IS_TTY )); then printf '\033[?25h'; fi; }

cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM
  stop_cursor_hidden
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf "$TMP_DIR"; fi
  if (( rc != 0 && STARTED )) && [[ $COMMAND == install ]]; then
    printf '\n'; hr
    emit "$S_ERR" "$C_ERR" "OldBox stopped before finishing (exit code $rc)."
    emit "$S_INFO" "$C_INFO" "Every step is idempotent: fix the cause, then re-run the same command."
    emit "$S_INFO" "$C_INFO" "Full details: $LOG_FILE"
  fi
  exit "$rc"
}

on_err() { # on_err rc line command
  local rc=$1 line=$2 cmd=$3
  trap - ERR
  if (( IS_TTY )); then printf '\r\033[2K\033[?25h'; fi
  printf '\n'
  emit "$S_ERR" "$C_ERR" "Unexpected error (exit $rc) on line $line: $cmd"
  log_raw "ERR   rc=$rc line=$line cmd=$cmd"
  exit "$rc"
}

on_signal() {
  trap - INT TERM
  if (( IS_TTY )); then printf '\r\033[2K\033[?25h'; fi
  printf '\n'
  emit "$S_WARN" "$C_WARN" "Interrupted. It is safe to run OldBox again at any time."
  exit 130
}

die() { # die "what happened" ["what to do about it"]
  trap - ERR
  if (( IS_TTY )); then printf '\r\033[2K\033[?25h'; fi
  printf '\n'
  emit "$S_ERR" "$C_ERR" "$1"
  if [[ -n ${2:-} ]]; then emit "$S_ARROW" "$C_INFO" "$2"; fi
  log_raw "FATAL $1"
  exit 1
}

quiet() { # run a silent mutation (honours --dry-run, output goes to the log)
  if (( DRY_RUN )); then return 0; fi
  "$@" >>"$LOG_FILE" 2>&1
}

retry() { # retry N cmd...   (3s, 6s, 9s ... back-off)
  local n=$1 i=1
  shift
  until "$@"; do
    if (( i >= n )); then return 1; fi
    sleep $(( i * 3 ))
    i=$(( i + 1 ))
  done
}

# run "label" cmd...  — animated spinner while cmd runs; its output goes to the log
run() {
  local label=$1 rc=0 start=$SECONDS took pid i=0 shown out l
  shift
  log_raw "RUN   $label :: $*"
  if (( DRY_RUN )); then emit "$S_DOT" "$C_MUTED" "[dry-run] $label"; return 0; fi
  out=$(mktemp "$TMP_DIR/run.XXXXXX")

  if (( ANIMATE )); then
    ( trap - ERR; set +e; "$@" ) </dev/null >"$out" 2>&1 &
    pid=$!
    printf '\033[?25l'
    while kill -0 "$pid" 2>/dev/null; do
      shown=$(trunc "$label" $(( W - 14 )))
      printf '\r\033[2K  %s%s%s %s %s%ds%s' \
        "$C_ACCENT" "${SPIN[i % ${#SPIN[@]}]}" "$C_RESET" "$shown" "$C_MUTED" $(( SECONDS - start )) "$C_RESET"
      i=$(( i + 1 ))
      sleep 0.08
    done
    wait "$pid" || rc=$?
    printf '\r\033[2K\033[?25h'
  else
    emit "$S_DOT" "$C_MUTED" "$label ..."
    ( trap - ERR; set +e; "$@" ) </dev/null >"$out" 2>&1 || rc=$?
  fi
  cat "$out" >>"$LOG_FILE" 2>/dev/null || true

  took=$(( SECONDS - start ))
  if (( rc == 0 )); then
    msg_ok "$label (${took}s)"
    rm -f "$out"
    return 0
  fi
  if (( RUN_OPT )); then
    msg_warn "$label: skipped (exit $rc, non-fatal)"
  else
    msg_err "$label: failed (exit $rc). Last output:"
    tail -n 8 "$out" 2>/dev/null | while IFS= read -r l; do
      printf '      %s%s%s\n' "$C_MUTED" "$(trunc "$l" $(( W - 10 )))" "$C_RESET"
    done
  fi
  rm -f "$out"
  return "$rc"
}

run_opt() { RUN_OPT=1; run "$@" || true; RUN_OPT=0; }                       # failure = warning
run_try() { local rc=0; RUN_OPT=1; run "$@" || rc=$?; RUN_OPT=0; return "$rc"; }  # failure = status

# =============================================================================
# 4. Input helpers (work interactively, via pipes, and fully unattended)
# =============================================================================
can_prompt() { (( ! ASSUME_YES && HAVE_TTY )); }

ask() { # ask VAR "Question" "default" [regex] [hint]   (locals are __-prefixed so VAR may be any caller name)
  local __var=$1 __q=$2 __def=$3 __re=${4:-} __hint=${5:-} __ans __tries=0
  if ! can_prompt; then printf -v "$__var" '%s' "$__def"; return 0; fi
  while (( __tries < 5 )); do
    printf '  %s?%s %s %s[%s]%s ' "$C_ACCENT2" "$C_RESET" "$__q" "$C_MUTED" "$__def" "$C_RESET" >&2
    IFS= read -r __ans </dev/tty || __ans=""
    __ans=${__ans:-$__def}
    if [[ -z $__re || $__ans =~ $__re ]]; then printf -v "$__var" '%s' "$__ans"; return 0; fi
    msg_warn "${__hint:-That does not look right, please try again.}"
    __tries=$(( __tries + 1 ))
  done
  printf -v "$__var" '%s' "$__def"
}

ask_secret() { # ask_secret VAR "Question"  (input hidden)
  local __var=$1 __q=$2 __ans=""
  if ! can_prompt; then return 0; fi
  printf '  %s?%s %s %s(hidden)%s ' "$C_ACCENT2" "$C_RESET" "$__q" "$C_MUTED" "$C_RESET" >&2
  IFS= read -rs __ans </dev/tty || __ans=""
  printf '\n' >&2
  printf -v "$__var" '%s' "$__ans"
}

confirm() { # confirm "Question" y|n   -> status 0 = yes
  local q=$1 def=${2:-y} ans hint='Y/n'
  if [[ $def == n ]]; then hint='y/N'; fi
  if ! can_prompt; then [[ $def == y ]]; return; fi
  while true; do
    printf '  %s?%s %s %s[%s]%s ' "$C_ACCENT2" "$C_RESET" "$q" "$C_MUTED" "$hint" "$C_RESET" >&2
    IFS= read -r ans </dev/tty || ans=""
    case ${ans,,} in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      '')    [[ $def == y ]]; return ;;
    esac
  done
}

enabled() { local v="WITH_${1^^}"; [[ "${!v:-no}" == yes ]]; }

is_answer_key() { local k; for k in "${ANSWER_KEYS[@]}"; do [[ $k == "$1" ]] && return 0; done; return 1; }

component_menu() {
  can_prompt || return 0
  local ans tok i id var mark idx
  while true; do
    printf '\n  %sChoose what to install%s\n' "$C_BOLD$C_ACCENT" "$C_RESET"
    printf '  %sType numbers to toggle (e.g. 3 7 9), a = all, n = none, Enter = continue%s\n\n' "$C_MUTED" "$C_RESET"
    i=1
    for id in "${COMP_IDS[@]}"; do
      var="WITH_${id^^}"
      if [[ ${!var} == yes ]]; then mark="${C_OK}${S_CHECK}${C_RESET}"; else mark="${C_MUTED}${S_UNCHECK}${C_RESET}"; fi
      printf '  %s%2d%s %s %s\n' "$C_MUTED" "$i" "$C_RESET" "$mark" "$(trunc "${COMP_DESC[$id]}" $(( W - 14 )))"
      i=$(( i + 1 ))
    done
    printf '\n  %s%s%s ' "$C_ACCENT2" "$S_ARROW" "$C_RESET" >&2
    IFS= read -r ans </dev/tty || ans=""
    if [[ -z $ans ]]; then break; fi
    case ${ans,,} in
      a) for id in "${COMP_IDS[@]}"; do printf -v "WITH_${id^^}" '%s' yes; done ;;
      n) for id in "${COMP_IDS[@]}"; do printf -v "WITH_${id^^}" '%s' no; done ;;
      *)
        for tok in ${ans//,/ }; do
          if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#COMP_IDS[@]} )); then
            idx=$(( tok - 1 )); id=${COMP_IDS[idx]}; var="WITH_${id^^}"
            if [[ ${!var} == yes ]]; then printf -v "$var" '%s' no; else printf -v "$var" '%s' yes; fi
          fi
        done ;;
    esac
  done
}

choose_tunnel() {
  can_prompt || return 0
  local -a modes=(none lan tailscale cloudflare direct)
  local -a descs=(
    "none        localhost only; reach apps through Tailscale or SSH tunnels"
    "lan         expose web apps on your home network (http://<ip>:8080)"
    "tailscale   free public https://<machine>.<tailnet>.ts.net (Funnel)"
    "cloudflare  Cloudflare Tunnel: your domain, no open router ports"
    "direct      your domain + router port-forwarding (80/443)"
  )
  local i ans def=1
  for i in "${!modes[@]}"; do if [[ ${modes[i]} == "$TUNNEL_MODE" ]]; then def=$(( i + 1 )); fi; done
  printf '\n  %sHow should the internet reach your web apps?%s\n\n' "$C_BOLD$C_ACCENT" "$C_RESET"
  for i in "${!descs[@]}"; do
    printf '  %s%d%s  %s\n' "$C_MUTED" $(( i + 1 )) "$C_RESET" "$(trunc "${descs[i]}" $(( W - 8 )))"
  done
  ask ans "Pick 1-5" "$def" '^[1-5]$' "Please type a number from 1 to 5."
  TUNNEL_MODE=${modes[ans-1]}
}

# =============================================================================
# 5. System abstraction: OS family, package manager, firewall driver
# =============================================================================
OS_ID="" OS_LIKE="" OS_NAME="" OS_VERSION_ID="" OS_CODENAME="" OS_UBUNTU_CODENAME=""
FAMILY=unknown FW_DRIVER=none ADMIN_GROUP=sudo SSH_UNIT=sshd SEL_RO=":ro" SEL_RW=""

detect_os() {
  if [[ -r /etc/os-release ]]; then
    local k v
    while IFS='=' read -r k v; do
      v=${v%\"}; v=${v#\"}
      case $k in
        ID) OS_ID=$v ;; ID_LIKE) OS_LIKE=$v ;; PRETTY_NAME) OS_NAME=$v ;;
        VERSION_ID) OS_VERSION_ID=$v ;; VERSION_CODENAME) OS_CODENAME=$v ;;
        UBUNTU_CODENAME) OS_UBUNTU_CODENAME=$v ;;
      esac
    done </etc/os-release
  fi
  OS_NAME=${OS_NAME:-${OS_ID:-unknown}}
  case " $OS_ID $OS_LIKE " in
    *" debian "*|*" ubuntu "*) FAMILY=debian ;;
    *" fedora "*|*" rhel "*|*" centos "*) FAMILY=rhel ;;
    *" arch "*) FAMILY=arch ;;
    *" suse "*|*" opensuse "*|*" sles "*) FAMILY=suse ;;
    *) FAMILY=unknown ;;
  esac
  case $FAMILY in
    debian|arch) FW_DRIVER=ufw ;;
    rhel|suse)   FW_DRIVER=firewalld ;;
  esac
  if [[ $FAMILY == debian ]]; then ADMIN_GROUP=sudo; else ADMIN_GROUP=wheel; fi
  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null || true) == Enforcing ]]; then
    SEL_RO=":ro,z"; SEL_RW=":z"
  fi
}

pm_update() {
  case $FAMILY in
    debian) apt-get update -o DPkg::Lock::Timeout=180 ;;
    rhel)   "$(command -v dnf || command -v yum)" -y makecache ;;
    arch)   true ;;   # a bare "pacman -Sy" risks partial upgrades; pm_upgrade does -Syu
    suse)   zypper --non-interactive --gpg-auto-import-keys refresh ;;
  esac
}
pm_upgrade() {
  case $FAMILY in
    debian) apt-get -y -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold upgrade ;;
    rhel)   "$(command -v dnf || command -v yum)" -y upgrade --refresh ;;
    arch)   pacman -Syu --noconfirm ;;
    suse)   zypper --non-interactive update ;;
  esac
}
pm_install() {
  case $FAMILY in
    debian) apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confold "$@" ;;
    rhel)   "$(command -v dnf || command -v yum)" -y install "$@" ;;
    arch)   pacman -S --needed --noconfirm "$@" ;;
    suse)   zypper --non-interactive install --no-recommends "$@" ;;
  esac
}
pm_install_each() { local p rc=0; for p in "$@"; do pm_install "$p" || { echo "optional package skipped: $p"; rc=0; }; done; return "$rc"; }

pkg() { # map a generic package name to this distro's name
  case "$1:$FAMILY" in
    ssh-server:arch|ssh-server:suse) echo openssh ;;
    ssh-server:*) echo openssh-server ;;
    iproute:rhel) echo iproute ;;
    iproute:*) echo iproute2 ;;
    firewall:debian|firewall:arch) echo ufw ;;
    firewall:*) echo firewalld ;;
    *) echo "$1" ;;
  esac
}

unit_exists() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }
enable_first_unit() { local u; for u in "$@"; do if unit_exists "$u.service"; then systemctl enable --now "$u"; return; fi; done; return 1; }
ssh_reload() { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd; }

ssh_ports() { # every port sshd listens on + the port of the current session
  local sshd_bin ports="" p
  sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
  if [[ -x $sshd_bin ]]; then
    if (( ! DRY_RUN )); then mkdir -p /run/sshd 2>/dev/null || true; fi
    ports=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ') || true
  fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    p=$(awk '{print $4}' <<<"$SSH_CONNECTION")
    if [[ $p =~ ^[0-9]+$ ]]; then ports+=" $p"; fi
  fi
  ports=$(tr ' ' '\n' <<<"$ports" | awk 'NF' | sort -un | tr '\n' ' ') || true
  if [[ -z ${ports// /} ]]; then ports=22; fi
  printf '%s' "$ports"
}

# =============================================================================
# 6. Config: answers file, state file, managed file writer, secrets, .env
# =============================================================================
state_get() { [[ -f $STATE_FILE ]] || return 0; grep -m1 "^$1=" "$STATE_FILE" | cut -d= -f2- || true; }
state_set() {
  local tmp
  tmp=$(mktemp "$TMP_DIR/st.XXXXXX")
  if [[ -f $STATE_FILE ]]; then grep -v "^$1=" "$STATE_FILE" >"$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  install -m 600 "$tmp" "$STATE_FILE"
}

mark_env_explicit() {
  local k
  for k in "${ANSWER_KEYS[@]}"; do if [[ -n "${!k+x}" ]]; then EXPLICIT[$k]=1; fi; done
}

load_answers() {
  [[ -r $ANSWERS_FILE ]] || return 0
  local line k v
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Z_]+)=(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    is_answer_key "$k" || continue
    [[ -z ${EXPLICIT[$k]:-} ]] || continue
    printf -v "$k" '%s' "$v"
  done <"$ANSWERS_FILE"
}

save_answers() {
  (( DRY_RUN )) && return 0
  local k tmp
  tmp=$(mktemp "$TMP_DIR/ans.XXXXXX")
  for k in "${ANSWER_KEYS[@]}"; do
    if [[ -n "${!k+x}" ]]; then printf '%s=%s\n' "$k" "${!k}" >>"$tmp"; fi
  done
  install -m 600 "$tmp" "$ANSWERS_FILE"
}

detect_timezone() {
  local tz
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  if [[ -z $tz && -r /etc/timezone ]]; then tz=$(head -n1 /etc/timezone); fi
  printf '%s' "${tz:-UTC}"
}

detect_admin_user() {
  if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then printf '%s' "$SUDO_USER"; return; fi
  getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /(nologin|false)$/ {print $1; exit}' || true
}

apply_defaults() {
  : "${STACK_DIR:=/opt/oldbox}" "${TUNNEL_MODE:=none}" "${DOMAIN:=}" "${ACME_EMAIL:=}"
  : "${GITHUB_KEYS_USER:=}" "${BATTERY_LIMIT:=80}" "${SWAPPINESS:=10}" "${JOURNAL_MAX:=200M}"
  : "${BACKUP_KEEP_DAYS:=7}" "${BACKUP_TIME:=03:30}" "${BACKUP_REMOTE:=}"
  : "${ADMIN_BIND:=127.0.0.1}" "${WEB_HTTP_PORT:=8080}" "${DO_UPGRADE:=yes}"
  : "${SSH_PUBKEY:=}" "${CF_TUNNEL_TOKEN:=}"
  if [[ -z ${TIMEZONE:-} ]]; then TIMEZONE=$(detect_timezone); fi
  if [[ -z ${ADMIN_USER:-} ]]; then ADMIN_USER=$(detect_admin_user); fi
  local id v
  for id in "${COMP_IDS[@]}"; do
    v="WITH_${id^^}"
    if [[ -z ${!v:-} ]]; then printf -v "$v" '%s' "${COMP_DEF[$id]}"; fi
  done
}

# Writes stdin to PATH without ever clobbering the user's own edits.
#   write_managed PATH [MODE] [force]
#   - missing file          -> created
#   - identical             -> untouched
#   - unchanged since we wrote it (or "force") -> updated (first original kept as .oldbox.bak)
#   - edited by the user    -> left alone, new version saved as PATH.new
write_managed() {
  local f=$1 mode=${2:-644} force=${3:-} tmp new cur prev key
  tmp=$(mktemp "$TMP_DIR/wm.XXXXXX")
  cat >"$tmp"
  if (( DRY_RUN )); then emit "$S_DOT" "$C_MUTED" "[dry-run] would write $f"; return 0; fi
  mkdir -p "$(dirname "$f")"
  new=$(sha256sum "$tmp" | cut -d' ' -f1)
  key="sum.$(printf '%s' "$f" | sha256sum | cut -c1-12)"
  if [[ ! -e $f ]]; then
    install -m "$mode" "$tmp" "$f"; state_set "$key" "$new"
    msg_ok "Created $f"; return 0
  fi
  cur=$(sha256sum "$f" | cut -d' ' -f1)
  if [[ $cur == "$new" ]]; then state_set "$key" "$new"; return 0; fi
  prev=$(state_get "$key")
  if [[ -n $force || $cur == "$prev" ]]; then
    if [[ -z $prev && ! -e $f.oldbox.bak ]]; then cp -p "$f" "$f.oldbox.bak"; fi
    install -m "$mode" "$tmp" "$f"; state_set "$key" "$new"
    msg_ok "Updated $f"; return 0
  fi
  install -m "$mode" "$tmp" "$f.new"
  msg_warn "Kept your edits in $f; the new version is saved as $f.new"
}

write_once() { # write_once PATH [MODE]  — only if the file does not exist yet
  local f=$1 mode=${2:-644} tmp
  tmp=$(mktemp "$TMP_DIR/wo.XXXXXX")
  cat >"$tmp"
  if (( DRY_RUN )); then return 0; fi
  if [[ -e $f ]]; then return 0; fi
  mkdir -p "$(dirname "$f")"
  install -m "$mode" "$tmp" "$f"
}

gen_secret() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

env_path() { printf '%s/.env' "$STACK_DIR"; }
env_get() { local f; f=$(env_path); [[ -f $f ]] || return 0; grep -m1 "^$1=" "$f" | cut -d= -f2- || true; }
env_set() {
  (( DRY_RUN )) && return 0
  local f tmp
  f=$(env_path); tmp=$(mktemp "$TMP_DIR/env.XXXXXX")
  if [[ -f $f ]]; then grep -v "^$1=" "$f" >"$tmp" || true; fi
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  install -m 600 "$tmp" "$f"
}
env_ensure_secret() { if [[ -z "$(env_get "$1")" ]]; then env_set "$1" "$(gen_secret)"; fi; }

# =============================================================================
# 7. Validation, wizard, pre-flight checks, plan
# =============================================================================
ARG_ERR=""
set_components() { # set_components yes|no a,b,c
  local state=$1 list=$2 n id
  local -a items
  IFS=',' read -ra items <<<"$list"
  for n in "${items[@]}"; do
    n=${n,,}
    if [[ $n == all ]]; then
      for id in "${COMP_IDS[@]}"; do printf -v "WITH_${id^^}" '%s' "$state"; EXPLICIT["WITH_${id^^}"]=1; done
    elif [[ " ${COMP_IDS[*]} " == *" $n "* ]]; then
      printf -v "WITH_${n^^}" '%s' "$state"; EXPLICIT["WITH_${n^^}"]=1
    else
      ARG_ERR="Unknown component '$n'. Valid: ${COMP_IDS[*]}"
    fi
  done
}

usage() {
  banner
  cat <<EOF

${C_BOLD}USAGE${C_RESET}
  sudo ./oldbox.sh [command] [options]

${C_BOLD}COMMANDS${C_RESET}
  install        Set everything up (default). Safe to re-run.
  check          Run the pre-flight checks only; change nothing.
  status         Show health: resources, containers, temperature, battery.
  update         Pull newer container images and recreate what changed.
  backup         Run the nightly backup job right now.

${C_BOLD}OPTIONS${C_RESET}
  -y, --yes                 Non-interactive: accept defaults and flags.
  -n, --dry-run             Show what would happen; change nothing.
      --user NAME           Admin account that owns Docker/SSH keys.
      --timezone TZ         e.g. Asia/Kuwait, Europe/Paris.
      --stack-dir DIR       Where the Docker stack lives (default /opt/oldbox).
      --with a,b,c          Enable components (or 'all').
      --without a,b,c       Disable components.
      --tunnel MODE         none | lan | tailscale | cloudflare | direct
      --domain NAME         Your domain (direct / cloudflare).
      --email ADDR          Email for Let's Encrypt (direct mode).
      --github-keys USER    Import SSH public keys from github.com/USER.keys
      --skip-upgrade        Do not upgrade OS packages first.
      --no-color --no-anim --ascii   Plain output for odd terminals.
  -V, --version             Print version.  -h, --help  This help.

${C_BOLD}COMPONENTS${C_RESET}
  ${COMP_IDS[*]}

${C_BOLD}EXAMPLES${C_RESET}
  sudo ./oldbox.sh                          Guided, interactive install
  sudo ./oldbox.sh --dry-run                Preview without changing anything
  sudo ./oldbox.sh -y --github-keys octocat Unattended with GitHub SSH keys
  sudo ./oldbox.sh -y --with mongo,adminer --tunnel tailscale
  oldbox status                             Health dashboard (after install)

${C_MUTED}Environment variables with the same names (ADMIN_USER, TIMEZONE, DOMAIN,
CF_TUNNEL_TOKEN, SSH_PUBKEY, ...) work too. Log: $LOG_FILE${C_RESET}
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
    esac
    case $1 in
      install|check|status|update|backup|help) COMMAND=$1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --no-color) FORCE_NO_COLOR=1 ;;
      --no-anim) FORCE_NO_ANIM=1 ;;
      --ascii) FORCE_ASCII=1 ;;
      --skip-upgrade) DO_UPGRADE=no; EXPLICIT[DO_UPGRADE]=1 ;;
      --user)       ADMIN_USER=${2:?--user needs a value}; EXPLICIT[ADMIN_USER]=1; shift ;;
      --timezone)   TIMEZONE=${2:?--timezone needs a value}; EXPLICIT[TIMEZONE]=1; shift ;;
      --stack-dir)  STACK_DIR=${2:?--stack-dir needs a value}; EXPLICIT[STACK_DIR]=1; shift ;;
      --tunnel)     TUNNEL_MODE=${2:?--tunnel needs a value}; EXPLICIT[TUNNEL_MODE]=1; shift ;;
      --domain)     DOMAIN=${2:?--domain needs a value}; EXPLICIT[DOMAIN]=1; shift ;;
      --email)      ACME_EMAIL=${2:?--email needs a value}; EXPLICIT[ACME_EMAIL]=1; shift ;;
      --github-keys) GITHUB_KEYS_USER=${2:?--github-keys needs a value}; EXPLICIT[GITHUB_KEYS_USER]=1; shift ;;
      --with)       set_components yes "${2:?--with needs a list}"; shift ;;
      --without)    set_components no "${2:?--without needs a list}"; shift ;;
      -h|--help) COMMAND=help ;;
      -V|--version) printf 'oldbox %s\n' "$OLDBOX_VERSION"; exit 0 ;;
      *) printf 'oldbox: unknown option or command: %s\nTry: oldbox --help\n' "$1" >&2; exit 2 ;;
    esac
    shift
  done
  if [[ -n $ARG_ERR ]]; then printf 'oldbox: %s\n' "$ARG_ERR" >&2; exit 2; fi
}

validate_inputs() {
  local re_domain='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
  [[ -n $ADMIN_USER ]] || die "No admin user could be determined." \
    "Create one first (adduser NAME, or useradd -m NAME) and pass it with --user NAME."
  id "$ADMIN_USER" >/dev/null 2>&1 || die "User '$ADMIN_USER' does not exist." \
    "Create it first: adduser $ADMIN_USER   (Arch/Fedora/SUSE: useradd -m -G $ADMIN_GROUP $ADMIN_USER)"
  [[ $ADMIN_USER != root ]] || die "The admin user cannot be root." "Use a normal account and pass it with --user NAME."
  [[ $STACK_DIR =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Invalid --stack-dir '$STACK_DIR'." "Use an absolute path without spaces, e.g. /opt/oldbox."
  case $TUNNEL_MODE in none|lan|tailscale|cloudflare|direct) ;; *) die "Invalid tunnel mode '$TUNNEL_MODE'." "Use: none | lan | tailscale | cloudflare | direct" ;; esac
  [[ $BACKUP_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "Invalid backup time '$BACKUP_TIME'." "Use HH:MM, e.g. 03:30."
  if [[ ! $BATTERY_LIMIT =~ ^[0-9]+$ ]] || (( BATTERY_LIMIT < 50 || BATTERY_LIMIT > 100 )); then
    die "Battery limit must be 50-100." "Example: BATTERY_LIMIT=80 sudo -E ./oldbox.sh"
  fi
  if [[ ! $WEB_HTTP_PORT =~ ^[0-9]+$ ]] || (( WEB_HTTP_PORT < 1 || WEB_HTTP_PORT > 65535 )); then
    die "Invalid web port '$WEB_HTTP_PORT'." "Use a number between 1 and 65535."
  fi
  [[ $ADMIN_BIND =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid ADMIN_BIND '$ADMIN_BIND'." "Use an IPv4 address such as 127.0.0.1 (private) or 0.0.0.0 (all interfaces)."
  [[ $JOURNAL_MAX =~ ^[0-9]+[KMG]$ ]] || die "Invalid JOURNAL_MAX '$JOURNAL_MAX'." "Example: 200M"
  if [[ ! $SWAPPINESS =~ ^[0-9]+$ ]] || (( SWAPPINESS > 100 )); then die "SWAPPINESS must be a number from 0 to 100."; fi
  if [[ -n $GITHUB_KEYS_USER && ! $GITHUB_KEYS_USER =~ ^[A-Za-z0-9-]{1,39}$ ]]; then die "Invalid GitHub username '$GITHUB_KEYS_USER'."; fi
  if [[ $TUNNEL_MODE == direct || $TUNNEL_MODE == cloudflare ]] && [[ -n $DOMAIN && ! $DOMAIN =~ $re_domain ]]; then
    die "'$DOMAIN' does not look like a domain name." "Example: example.com or app.example.com"
  fi
  if [[ -n $CF_TUNNEL_TOKEN && ! $CF_TUNNEL_TOKEN =~ ^[A-Za-z0-9=_.-]+$ ]]; then die "CF_TUNNEL_TOKEN contains unexpected characters."; fi
}

# Resolve dependencies between choices and derive networking values.
WEB_BIND=127.0.0.1 WEB_HTTPS_PORT=8443 OPEN_WEB=no
normalize_selection() {
  if enabled phpmyadmin && ! enabled mariadb; then WITH_MARIADB=yes; msg_info "phpMyAdmin needs MariaDB, so it was switched on."; fi
  if enabled php && ! enabled caddy; then WITH_CADDY=yes; msg_info "PHP is served through Caddy, so Caddy was switched on."; fi
  case $TUNNEL_MODE in
    lan|cloudflare|direct|tailscale)
      if ! enabled caddy; then WITH_CADDY=yes; msg_info "Public/LAN access goes through Caddy, so it was switched on."; fi ;;
  esac
  if [[ $TUNNEL_MODE == tailscale ]] && ! enabled tailscale; then WITH_TAILSCALE=yes; fi
  if [[ $TUNNEL_MODE == cloudflare && -z $CF_TUNNEL_TOKEN && -z "$(env_get CF_TUNNEL_TOKEN)" ]]; then
    msg_warn "No CF_TUNNEL_TOKEN supplied, so Cloudflare Tunnel is skipped. Set it and re-run, or add it to $STACK_DIR/.env."
    TUNNEL_MODE=none
  fi
  if [[ $TUNNEL_MODE == direct && -z $DOMAIN ]]; then
    msg_warn "Direct mode needs --domain; falling back to LAN-only."
    TUNNEL_MODE=lan
  fi
  case $TUNNEL_MODE in
    none|tailscale|cloudflare) WEB_BIND=127.0.0.1; OPEN_WEB=no ;;
    lan)    WEB_BIND=0.0.0.0; OPEN_WEB=no ;;
    direct) WEB_BIND=0.0.0.0; WEB_HTTP_PORT=80; WEB_HTTPS_PORT=443; OPEN_WEB=yes ;;
  esac
}

stack_services() { # services (compose profiles) that will run
  local id out=()
  for id in postgres redis mariadb mongo caddy kuma dozzle adminer phpmyadmin php; do
    if enabled "$id"; then out+=("$id"); fi
  done
  if [[ $TUNNEL_MODE == cloudflare ]]; then out+=(cloudflared); fi
  printf '%s ' "${out[@]+"${out[@]}"}"
}

wizard() {
  can_prompt || return 0
  banner
  printf '\n  %sWelcome!%s This guided setup asks a few questions, then does the rest.\n' "$C_BOLD" "$C_RESET"
  printf '  %sPress Enter to accept the value in [brackets]. Nothing changes until you confirm.%s\n' "$C_MUTED" "$C_RESET"
  section "Basics"
  ask ADMIN_USER "Admin user (owns Docker + SSH keys)" "${ADMIN_USER:-}" '^[a-z_][a-z0-9_-]*$' "Use an existing Linux username."
  ask TIMEZONE "Timezone" "$TIMEZONE" '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$' "Example: Asia/Kuwait"
  ask STACK_DIR "Install the Docker stack in" "$STACK_DIR" '^/[A-Za-z0-9._/-]+$' "Absolute path, no spaces."
  component_menu
  if enabled caddy || enabled php || [[ $TUNNEL_MODE != none ]]; then
    choose_tunnel
    case $TUNNEL_MODE in
      direct) ask DOMAIN "Your domain" "$DOMAIN" '^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$' "Example: example.com"
              ask ACME_EMAIL "Email for Let's Encrypt (optional)" "$ACME_EMAIL" '^([^@ ]+@[^@ ]+\.[^@ ]+)?$' "Example: you@example.com" ;;
      cloudflare)
              ask DOMAIN "Your domain (for reference)" "$DOMAIN" '^(([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,})?$' "Example: example.com"
              if [[ -z $CF_TUNNEL_TOKEN ]]; then ask_secret CF_TUNNEL_TOKEN "Cloudflare Tunnel token (Zero Trust > Networks > Tunnels)"; fi ;;
    esac
  fi
  section "SSH access"
  local home ak
  home=$(getent passwd "$ADMIN_USER" 2>/dev/null | cut -d: -f6 || true)
  ak="$home/.ssh/authorized_keys"
  if enabled ssh && [[ ! -s $ak && -z $SSH_PUBKEY && -z $GITHUB_KEYS_USER ]]; then
    msg_info "No SSH key found for $ADMIN_USER. Importing one lets OldBox switch to safe key-only login."
    ask GITHUB_KEYS_USER "GitHub username to import SSH keys from (blank = skip)" "" '^([A-Za-z0-9-]{1,39})?$' "GitHub usernames use letters, digits and hyphens."
  fi
}

PF_ROWS=0
chk() { # chk ok|warn|fail "label" "detail"
  local st=$1 label=$2 detail=${3:-} sym col
  case $st in
    ok)   sym=$S_OK;   col=$C_OK ;;
    warn) sym=$S_WARN; col=$C_WARN; WARNINGS+=("$label: $detail") ;;
    fail) sym=$S_ERR;  col=$C_ERR;  PF_FAIL=$(( PF_FAIL + 1 )) ;;
  esac
  printf '  %s%s%s %-16s %s\n' "$col" "$sym" "$C_RESET" "$(trunc "$label" 16)" "$(trunc "$detail" $(( W - 26 )))"
  log_raw "CHECK $st $label: $detail"
  PF_ROWS=$(( PF_ROWS + 1 ))
}

preflight() {
  PF_FAIL=0
  section "Pre-flight checks"
  if [[ $FAMILY == unknown ]]; then
    chk fail "System" "$OS_NAME is not supported (need Debian/Ubuntu, Fedora/RHEL, Arch or openSUSE family)"
  else
    chk ok "System" "$OS_NAME  [$FAMILY family]"
  fi
  if (( EUID == 0 )); then chk ok "Privileges" "running as root"
  elif (( DRY_RUN )) || [[ $COMMAND == check ]]; then chk warn "Privileges" "not root (fine for a preview)"
  else chk fail "Privileges" "root is required"; fi

  if [[ -d /run/systemd/system ]]; then HAVE_SYSTEMD=1; chk ok "Init system" "systemd"
  elif (( DRY_RUN )) || [[ $COMMAND == check ]]; then chk warn "Init system" "systemd not running here (preview only)"
  else chk fail "Init system" "systemd is required (containers/WSL without systemd are not supported)"; fi

  local arch bits
  arch=$(uname -m); bits=$(getconf LONG_BIT 2>/dev/null || echo 64)
  case $arch in
    x86_64|aarch64|armv7l)
      if [[ $bits == 64 || $arch == armv7l ]]; then chk ok "Architecture" "$arch ($bits-bit)"
      else chk fail "Architecture" "32-bit userland detected; install a 64-bit OS (Docker needs it)"; fi ;;
    *) chk fail "Architecture" "$arch is not supported by Docker's packages" ;;
  esac

  local ram disk cpus
  ram=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  cpus=$(nproc 2>/dev/null || echo 1)
  if (( ram >= 4096 )); then chk ok "Memory" "${ram} MB RAM, $cpus CPU core(s)"
  elif (( ram >= 2048 )); then chk warn "Memory" "${ram} MB RAM: fine for a lean stack; skip MongoDB/MariaDB"
  else chk warn "Memory" "${ram} MB RAM is low; keep to PostgreSQL or Redis only"; fi
  disk=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
  if (( disk >= 10000 )); then chk ok "Disk space" "$(( disk / 1024 )) GB free on /"
  elif (( disk >= 3000 )); then chk warn "Disk space" "$(( disk / 1024 )) GB free; images and databases need room"
  else chk fail "Disk space" "only ${disk} MB free on / (need at least 3 GB)"; fi

  if curl -fsSI --max-time 10 https://download.docker.com/linux/debian/gpg >/dev/null 2>&1; then
    chk ok "Internet" "download.docker.com reachable"
  elif (( DRY_RUN )) || [[ $COMMAND == check ]]; then
    chk warn "Internet" "download.docker.com not reachable from here (a real install needs it)"
  elif curl -fsSI --max-time 8 https://1.1.1.1 >/dev/null 2>&1; then
    chk fail "Internet" "online, but DNS or the Docker site is blocked (check /etc/resolv.conf)"
  else chk fail "Internet" "no connection (check cable/Wi-Fi, proxy and DNS)"; fi

  local def_if
  def_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}' || true)
  if [[ -n $def_if && -d /sys/class/net/$def_if/wireless ]]; then
    chk warn "Network" "using Wi-Fi ($def_if); Ethernet is more reliable for a server"
  elif [[ -n $def_if ]]; then chk ok "Network" "wired link ($def_if)"
  else chk warn "Network" "no default route detected"; fi

  if enabled mongo; then
    if [[ $arch == x86_64 ]] && ! grep -qw avx /proc/cpuinfo 2>/dev/null; then
      chk warn "MongoDB" "this CPU has no AVX; current MongoDB will not start, so it was disabled"
      WITH_MONGO=no
    else chk ok "MongoDB" "CPU instruction set looks compatible"; fi
  fi

  if enabled caddy && command -v ss >/dev/null 2>&1; then
    local busy
    busy=$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -E "[:.](${WEB_HTTP_PORT}|${WEB_HTTPS_PORT})$" | head -n1 || true)
    if [[ -n $busy ]]; then chk warn "Web ports" "something already listens on $busy; Caddy may fail to bind"
    else chk ok "Web ports" "${WEB_HTTP_PORT}/${WEB_HTTPS_PORT} are free"; fi
  fi

  if [[ -n ${SSH_CONNECTION:-} ]]; then chk ok "Session" "connected over SSH; your port will be kept open"; fi
  if (( PF_FAIL > 0 )); then
    die "$PF_FAIL pre-flight check(s) failed." "Fix the items marked above, then run again. Nothing was changed."
  fi
}

show_plan() {
  section "Plan"
  kv "Admin user" "$ADMIN_USER"
  kv "Timezone" "$TIMEZONE"
  kv "Stack folder" "$STACK_DIR"
  kv "Remote access" "$TUNNEL_MODE${DOMAIN:+  ($DOMAIN)}"
  local id on=() off=()
  for id in "${COMP_IDS[@]}"; do if enabled "$id"; then on+=("$id"); else off+=("$id"); fi; done
  kv "Installing" "${on[*]:-nothing}"
  kv "Skipping" "${off[*]:-nothing}"
  if (( DRY_RUN )); then printf '\n'; emit "$S_INFO" "$C_INFO" "Dry run: nothing will be changed."; fi
}

plan_steps() {
  STEPS=()
  STEPS+=("base|Preparing the system")
  STEPS+=("time|Clock and timezone")
  if enabled power;    then STEPS+=("power|Always-on laptop mode"); fi
  if enabled battery;  then STEPS+=("battery|Battery care"); fi
  if enabled ssd;      then STEPS+=("ssd|SSD and memory care"); fi
  if enabled updates;  then STEPS+=("updates|Automatic security updates"); fi
  STEPS+=("docker|Docker Engine and Compose")
  if enabled tailscale; then STEPS+=("tailscale|Tailscale VPN"); fi
  if enabled cockpit;   then STEPS+=("cockpit|Cockpit dashboard"); fi
  if enabled smart;     then STEPS+=("smart|Disk health monitoring"); fi
  STEPS+=("sshkeys|SSH keys")
  if enabled firewall;  then STEPS+=("firewall|Firewall"); fi
  if enabled ssh;       then STEPS+=("ssh|SSH hardening"); fi
  if [[ -n "$(stack_services)" ]]; then
    STEPS+=("stack|Writing the Docker stack")
    STEPS+=("launch|Starting your services")
  fi
  if enabled backups;   then STEPS+=("backups|Nightly backups"); fi
  STEPS+=("finish|Finishing touches")
  STEP_TOTAL=${#STEPS[@]}
}

# =============================================================================
# 8. Installation steps
# =============================================================================
admin_home() { getent passwd "$ADMIN_USER" | cut -d: -f6; }
admin_grp()  { id -gn "$ADMIN_USER"; }

step_base() {
  run "Refreshing package index" pm_update || die "Could not refresh package lists." "Check your internet connection and the repositories configured on this system."
  if [[ $DO_UPGRADE == yes ]]; then
    run "Upgrading installed packages (this can take a while)" pm_upgrade || die "Package upgrade failed." "Run it manually to see the error, then re-run OldBox (or add --skip-upgrade)."
  fi
  local req=(curl ca-certificates "$(pkg ssh-server)" sudo)
  run "Installing essentials (${req[*]})" pm_install "${req[@]}" || die "Could not install essential packages."
  run_opt "Installing helper tools (git htop tmux jq rsync openssl)" pm_install_each git htop tmux jq rsync openssl "$(pkg iproute)"
  run_opt "Enabling the SSH server at boot" enable_first_unit ssh sshd
  if getent group "$ADMIN_GROUP" >/dev/null 2>&1; then
    run_opt "Adding $ADMIN_USER to the '$ADMIN_GROUP' group" usermod -aG "$ADMIN_GROUP" "$ADMIN_USER"
  fi
}

step_time() {
  if [[ -f /usr/share/zoneinfo/$TIMEZONE ]]; then
    run_opt "Setting timezone to $TIMEZONE" timedatectl set-timezone "$TIMEZONE"
  else
    msg_warn "Unknown timezone '$TIMEZONE'; keeping the current one."
  fi
  run_opt "Enabling network time sync" timedatectl set-ntp true
}

step_power() {
  if ! compgen -G '/sys/class/power_supply/BAT*' >/dev/null 2>&1 && ! (( DRY_RUN )); then
    msg_dim "No battery found: this is not a laptop, applying sleep settings anyway (harmless)."
  fi
  write_managed /etc/systemd/logind.conf.d/00-oldbox-lid.conf 644 <<'EOF'
# Managed by OldBox: a server must keep running with the lid closed.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF
  run_opt "Disabling suspend and hibernate" systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
  run_opt "Reloading login settings" systemctl kill -s HUP systemd-logind
}

step_battery() {
  local files
  files=$(compgen -G '/sys/class/power_supply/BAT*/charge_control_end_threshold' 2>/dev/null; compgen -G '/sys/class/power_supply/BAT*/charge_stop_threshold' 2>/dev/null) || true
  if [[ -z $files ]] && (( ! DRY_RUN )); then
    msg_dim "This hardware exposes no charge-limit control (common on many laptops): skipped."
    return 0
  fi
  write_managed /etc/systemd/system/oldbox-battery.service 644 <<EOF
# Managed by OldBox: keep the battery healthy on an always-plugged-in server.
[Unit]
Description=OldBox battery charge limit (${BATTERY_LIMIT}%)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for f in /sys/class/power_supply/BAT*/charge_control_end_threshold /sys/class/power_supply/BAT*/charge_stop_threshold; do [ -w "\$f" ] && echo ${BATTERY_LIMIT} > "\$f"; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
  quiet systemctl daemon-reload
  run_opt "Enabling the ${BATTERY_LIMIT}% battery limit" systemctl enable --now oldbox-battery.service
}

step_ssd() {
  run_opt "Enabling weekly SSD TRIM" systemctl enable --now fstrim.timer
  write_managed /etc/sysctl.d/99-oldbox.conf 644 <<EOF
# Managed by OldBox: prefer RAM over swap to spare the SSD.
vm.swappiness=${SWAPPINESS}
EOF
  run_opt "Applying kernel settings" sysctl --system
  write_managed /etc/systemd/journald.conf.d/00-oldbox.conf 644 <<EOF
# Managed by OldBox: cap the system log so it can never fill the disk.
[Journal]
SystemMaxUse=${JOURNAL_MAX}
EOF
  run_opt "Restarting the journal" systemctl restart systemd-journald
}

step_updates() {
  case $FAMILY in
    debian)
      run "Installing unattended-upgrades" pm_install unattended-upgrades || die "Could not install unattended-upgrades."
      write_managed /etc/apt/apt.conf.d/20auto-upgrades 644 force <<'EOF'
// Managed by OldBox: refresh lists and install security updates daily.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
      ;;
    rhel)
      local timer=""
      if run_try "Installing dnf-automatic" pm_install dnf-automatic; then timer=dnf-automatic.timer
      elif run_try "Installing dnf5 automatic plugin" pm_install dnf5-plugin-automatic; then timer=dnf5-automatic.timer; fi
      if [[ -n $timer ]]; then
        write_managed /etc/dnf/automatic.conf 644 force <<'EOF'
# Managed by OldBox
[commands]
upgrade_type = security
apply_updates = yes
EOF
        run_opt "Enabling automatic security updates" systemctl enable --now "$timer"
      else
        msg_warn "Could not set up automatic updates on this system; update manually."
      fi ;;
    *) msg_dim "Rolling/enterprise-managed distro: automatic updates skipped on purpose (unattended upgrades can break rolling systems)." ;;
  esac
}

docker_have() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }

docker_repo_debian() {
  local os codename arch
  if [[ " $OS_ID $OS_LIKE " == *" ubuntu "* ]]; then os=ubuntu; codename=${OS_UBUNTU_CODENAME:-$OS_CODENAME}; else os=debian; codename=$OS_CODENAME; fi
  if [[ -z $codename || $codename == n/a ]]; then return 1; fi
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  run_try "Checking Docker publishes packages for $os/$codename" curl -fsSI --max-time 20 "https://download.docker.com/linux/$os/dists/$codename/Release" || return 1
  quiet install -m 0755 -d /etc/apt/keyrings
  run_try "Downloading Docker's signing key" retry 3 curl -fsSL --max-time 30 "https://download.docker.com/linux/$os/gpg" -o /etc/apt/keyrings/docker.asc || return 1
  quiet chmod a+r /etc/apt/keyrings/docker.asc
  write_managed /etc/apt/sources.list.d/docker.list 644 force <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$os $codename stable
EOF
  run_try "Refreshing package index" pm_update || return 1
  run_try "Installing Docker Engine + Compose (official packages)" pm_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

docker_repo_rpm() {
  local os major arch
  case $OS_ID in fedora) os=fedora ;; rhel) os=rhel ;; *) os=centos ;; esac
  major=${OS_VERSION_ID%%.*}
  arch=$(uname -m)
  run_try "Checking Docker publishes packages for $os $major" curl -fsSI --max-time 20 "https://download.docker.com/linux/$os/$major/$arch/stable/repodata/repomd.xml" || return 1
  run_try "Adding Docker's repository" retry 3 curl -fsSL --max-time 30 "https://download.docker.com/linux/$os/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo || return 1
  run_try "Installing Docker Engine + Compose (official packages)" pm_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

docker_install_distro() {
  local -a sets
  case $FAMILY in
    debian) sets=("docker.io docker-compose-v2" "docker.io docker-compose-plugin" "docker.io docker-compose") ;;
    rhel)   sets=("moby-engine docker-compose" "docker docker-compose-plugin" "docker") ;;
    arch|suse) sets=("docker docker-compose docker-buildx") ;;
  esac
  local s
  for s in "${sets[@]}"; do
    # shellcheck disable=SC2086
    if run_try "Installing Docker from the distribution ($s)" pm_install $s; then return 0; fi
  done
  return 1
}

configure_docker_daemon() {
  local f=/etc/docker/daemon.json ours merged tmp
  ours='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true}'
  if (( DRY_RUN )); then emit "$S_DOT" "$C_MUTED" "[dry-run] would configure $f (log rotation, live-restore)"; return 0; fi
  mkdir -p /etc/docker
  if [[ ! -f $f ]]; then
    printf '%s\n' "$ours" | jq . >"$f" 2>/dev/null || printf '%s\n' "$ours" >"$f"
    chmod 644 "$f"; DOCKER_RESTART=1; msg_ok "Created $f (log rotation + live-restore)"
  elif command -v jq >/dev/null 2>&1 && jq -e . "$f" >/dev/null 2>&1; then
    tmp=$(mktemp "$TMP_DIR/dj.XXXXXX")
    # existing keys win; we only add what is missing
    merged=$(jq -n --argjson a "$ours" --slurpfile b "$f" '$a * $b[0]')
    if [[ "$(jq -S . <<<"$merged")" != "$(jq -S . "$f")" ]]; then
      cp -p "$f" "$f.oldbox.bak"; printf '%s\n' "$merged" >"$tmp"; install -m 644 "$tmp" "$f"
      DOCKER_RESTART=1; msg_ok "Merged log-rotation defaults into your existing $f (backup: $f.oldbox.bak)"
    fi
  else
    msg_warn "$f exists and could not be merged automatically; add log rotation yourself."
  fi
}

step_docker() {
  if docker_have; then
    msg_ok "Docker already installed ($(docker --version 2>/dev/null | cut -d, -f1))"
  elif command -v docker >/dev/null 2>&1; then
    run_try "Adding the Compose plugin" pm_install docker-compose-plugin \
      || run_try "Adding the Compose plugin (alt)" pm_install docker-compose-v2 \
      || run_try "Adding docker-compose" pm_install docker-compose \
      || die "Docker is installed but Compose is missing." "Install the 'docker compose' plugin for your distro, then re-run."
  else
    local ok=0
    case $FAMILY in
      debian) if docker_repo_debian; then ok=1; fi ;;
      rhel)   if docker_repo_rpm; then ok=1; fi ;;
    esac
    if (( ! ok )); then
      msg_info "Official Docker packages are not available for this release; using the distribution's packages."
      docker_install_distro || die "Could not install Docker." "See $LOG_FILE. Your distro may need a manual Docker install: https://docs.docker.com/engine/install/"
    fi
  fi
  configure_docker_daemon
  run "Enabling Docker at boot" systemctl enable --now docker || die "The Docker service failed to start." "Check: systemctl status docker  and  journalctl -u docker"
  if (( DOCKER_RESTART )); then run_opt "Restarting Docker to apply settings" systemctl restart docker; fi
  run_opt "Adding $ADMIN_USER to the docker group" usermod -aG docker "$ADMIN_USER"
  if (( ! DRY_RUN )); then
    if ! docker network inspect oldbox_net >/dev/null 2>&1; then
      run "Creating the shared Docker network (oldbox_net)" docker network create oldbox_net || die "Could not create the Docker network."
    fi
  else emit "$S_DOT" "$C_MUTED" "[dry-run] would create Docker network oldbox_net"; fi
  run_opt "Testing Docker with hello-world" docker run --rm hello-world
}

step_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    msg_ok "Tailscale already installed"
  else
    local f="$TMP_DIR/tailscale-install.sh"
    run "Downloading the official Tailscale installer" retry 3 curl -fsSL --max-time 60 https://tailscale.com/install.sh -o "$f" || die "Could not download the Tailscale installer."
    run "Installing Tailscale" sh "$f" || die "Tailscale installation failed." "Install it manually from https://tailscale.com/download and re-run."
  fi
  run_opt "Starting the Tailscale service" systemctl enable --now tailscaled
}

step_cockpit() {
  run "Installing Cockpit" pm_install cockpit || { msg_warn "Cockpit is not available in this distro's repositories; skipped."; return 0; }
  run_opt "Starting Cockpit on port 9090" systemctl enable --now cockpit.socket
}

step_smart() {
  run_opt "Installing smartmontools" pm_install smartmontools
  run_opt "Starting disk health monitoring" enable_first_unit smartd smartmontools
}

step_sshkeys() {
  local home ak grp tmp gh_ok=0 added=0 k
  local -a keys=() gh=()
  home=$(admin_home); grp=$(admin_grp); ak="$home/.ssh/authorized_keys"
  if [[ -n $SSH_PUBKEY ]]; then keys+=("$SSH_PUBKEY"); fi
  if [[ -n $GITHUB_KEYS_USER ]]; then
    tmp="$TMP_DIR/gh.keys"
    if run_try "Fetching public keys for github.com/$GITHUB_KEYS_USER" retry 3 curl -fsSL --max-time 20 "https://github.com/${GITHUB_KEYS_USER}.keys" -o "$tmp"; then
      if [[ -s $tmp ]]; then gh_ok=1; fi
    fi
    if (( gh_ok )); then
      mapfile -t gh < <(grep -E '^(ssh-(rsa|ed25519)|ecdsa-sha2-|sk-)' "$tmp" || true)
      keys+=("${gh[@]+"${gh[@]}"}")
    elif (( ! DRY_RUN )); then
      msg_warn "No keys were found for github.com/$GITHUB_KEYS_USER."
    fi
  fi
  if (( ${#keys[@]} == 0 )); then
    if [[ -s $ak ]]; then msg_ok "SSH keys already present for $ADMIN_USER"
    else msg_info "No SSH key to import; password login will stay enabled (add a key later, then re-run)."; fi
    return 0
  fi
  if (( DRY_RUN )); then emit "$S_DOT" "$C_MUTED" "[dry-run] would install ${#keys[@]} SSH key(s) for $ADMIN_USER"; return 0; fi
  install -d -m 700 -o "$ADMIN_USER" -g "$grp" "$home/.ssh"
  touch "$ak"; chmod 600 "$ak"; chown "$ADMIN_USER:$grp" "$ak"
  for k in "${keys[@]}"; do
    if ! grep -qxF "$k" "$ak"; then printf '%s\n' "$k" >>"$ak"; added=$(( added + 1 )); fi
  done
  msg_ok "Installed $added new SSH key(s) for $ADMIN_USER"
}

step_firewall() {
  local ports p
  ports=$(ssh_ports)
  run "Installing the firewall ($FW_DRIVER)" pm_install "$(pkg firewall)" || die "Could not install the firewall package."
  case $FW_DRIVER in
    ufw)
      for p in $ports; do
        run "Allowing SSH on port $p (rate-limited)" ufw limit "$p/tcp" || die "Could not add the SSH firewall rule." "Not enabling the firewall to avoid locking you out."
      done
      if enabled tailscale; then run_opt "Trusting the Tailscale interface" ufw allow in on tailscale0; fi
      if [[ $OPEN_WEB == yes ]]; then
        run "Opening web ports 80 and 443" sh -c 'ufw allow 80/tcp && ufw allow 443/tcp' || die "Could not open web ports."
      fi
      run "Setting defaults (deny incoming, allow outgoing)" sh -c 'ufw default deny incoming && ufw default allow outgoing' || die "Could not set firewall defaults."
      run "Enabling the firewall" ufw --force enable || die "Could not enable the firewall."
      run_opt "Starting the firewall at boot" systemctl enable ufw ;;
    firewalld)
      run "Starting firewalld" systemctl enable --now firewalld || die "Could not start firewalld."
      for p in $ports; do
        run "Allowing SSH on port $p" firewall-cmd --permanent --add-port="$p/tcp" || die "Could not add the SSH firewall rule."
      done
      if enabled tailscale; then run_opt "Trusting the Tailscale interface" firewall-cmd --permanent --zone=trusted --add-interface=tailscale0; fi
      if [[ $OPEN_WEB == yes ]]; then
        run "Opening web ports 80 and 443" firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp || die "Could not open web ports."
      fi
      run "Applying firewall rules" firewall-cmd --reload || die "Could not apply firewall rules." ;;
  esac
  msg_info "Docker-published ports bypass the firewall by design; OldBox binds private services to 127.0.0.1."
}

step_ssh() {
  local home ak sshd_bin dropin=/etc/ssh/sshd_config.d/00-oldbox.conf main=/etc/ssh/sshd_config
  local kbd=KbdInteractiveAuthentication rootlogin=no pw
  home=$(admin_home); ak="$home/.ssh/authorized_keys"
  if [[ ! -s $ak ]] && (( ! DRY_RUN )); then
    msg_warn "No SSH key found for $ADMIN_USER, so password login stays ON (turning it off now would lock you out). Add a key, then re-run."
    return 0
  fi
  if (( DRY_RUN )); then emit "$S_DOT" "$C_MUTED" "[dry-run] would write $dropin (key-only SSH)"; return 0; fi
  sshd_bin=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
  mkdir -p /etc/ssh/sshd_config.d /run/sshd
  if ! grep -Eqi '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$main"; then
    cp -p "$main" "$main.oldbox.bak"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$main"
    msg_info "Added an Include line to $main (backup: $main.oldbox.bak)"
  fi
  if ! "$sshd_bin" -T 2>/dev/null | grep -qi '^kbdinteractiveauthentication'; then kbd=ChallengeResponseAuthentication; fi
  if [[ -n ${SSH_CONNECTION:-} && -z ${SUDO_USER:-} ]]; then
    rootlogin=prohibit-password
    msg_info "You are connected as root, so root login stays possible with keys only."
  fi
  write_managed "$dropin" 644 force <<EOF
# Managed by OldBox: key-only SSH.
PasswordAuthentication no
$kbd no
PermitRootLogin $rootlogin
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
  if ! "$sshd_bin" -t >>"$LOG_FILE" 2>&1; then
    rm -f "$dropin"
    if [[ -f $main.oldbox.bak ]]; then cp -p "$main.oldbox.bak" "$main"; fi
    die "sshd rejected the new configuration, so it was rolled back." "Your SSH access is unchanged. Details: $LOG_FILE"
  fi
  run "Applying SSH settings" ssh_reload || die "Could not reload the SSH service." "Your existing sessions stay open; check: systemctl status ssh"
  pw=$("$sshd_bin" -T 2>/dev/null | awk '$1=="passwordauthentication"{print $2}' || true)
  if [[ $pw == no ]]; then msg_ok "SSH is now key-only (verified in the effective config)"
  else msg_warn "Another config file still enables password login (effective value: ${pw:-unknown}). Check /etc/ssh/sshd_config.d/."; fi
  msg_info "Test it from a NEW terminal before closing this one:  ssh $ADMIN_USER@<this-machine>"
}

# ---------- stack files -------------------------------------------------------
emit_compose() {
  cat <<'YAML'
# =============================================================================
#  OldBox stack, generated by oldbox @VERSION@
#  Safe to edit: OldBox never overwrites your changes (it writes compose.yaml.new).
#  Turn services on/off with COMPOSE_PROFILES in .env, then:  docker compose up -d
#  Each service is its own profile, so enabling one never starts another.
# =============================================================================
name: oldbox

x-service: &service
  restart: unless-stopped
  networks: [oldbox]
  security_opt: ["no-new-privileges:true"]
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }

services:
  postgres:
    <<: *service
    profiles: [postgres]
    image: ${POSTGRES_IMAGE:-postgres:18}
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ:-UTC}
    command: ["postgres", "-c", "shared_buffers=${PG_SHARED_BUFFERS:-256MB}", "-c", "max_connections=${PG_MAX_CONNECTIONS:-60}"]
    volumes:
      - pgdata:/var/lib/postgresql   # PostgreSQL 18+ layout (17 and older: /var/lib/postgresql/data)
    ports:
      - "${DB_BIND:-127.0.0.1}:5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
    mem_limit: 1g

  redis:
    <<: *service
    profiles: [redis]
    image: ${REDIS_IMAGE:-redis:8-alpine}
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
      REDISCLI_AUTH: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --requirepass \"$$REDIS_PASSWORD\" --maxmemory ${REDIS_MAXMEMORY:-256mb} --maxmemory-policy noeviction"]
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 10
    mem_limit: 384m

  mariadb:
    <<: *service
    profiles: [mariadb]
    image: ${MARIADB_IMAGE:-mariadb:lts}
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      TZ: ${TZ:-UTC}
    volumes:
      - mariadbdata:/var/lib/mysql
    ports:
      - "${DB_BIND:-127.0.0.1}:3306:3306"
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    mem_limit: 768m

  mongo:
    <<: *service
    profiles: [mongo]
    image: ${MONGO_IMAGE:-mongo:8}
    command: ["mongod", "--wiredTigerCacheSizeGB", "${MONGO_CACHE_GB:-0.5}"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PASSWORD}
    volumes:
      - mongodata:/data/db
    ports:
      - "${DB_BIND:-127.0.0.1}:27017:27017"
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping').ok"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 30s
    mem_limit: 1g

  caddy:
    <<: *service
    profiles: [caddy]
    image: ${CADDY_IMAGE:-caddy:2}
    ports:
      - "${WEB_BIND:-127.0.0.1}:${WEB_HTTP_PORT:-8080}:80"
      - "${WEB_BIND:-127.0.0.1}:${WEB_HTTPS_PORT:-8443}:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile@ZRO@
      - ./sites:/srv@ZRO@
      - caddy_data:/data
      - caddy_config:/config
    mem_limit: 192m

  php:
    <<: *service
    profiles: [php]
    build: ./sites/php
    volumes:
      - ./sites/php/www:/srv/php/www@ZRW@
    mem_limit: 256m

  kuma:
    <<: *service
    profiles: [kuma]
    image: ${KUMA_IMAGE:-louislam/uptime-kuma:2}
    environment:
      TZ: ${TZ:-UTC}
    volumes:
      - kumadata:/app/data
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:3001:3001"
    mem_limit: 768m

  dozzle:
    <<: *service
    profiles: [dozzle]
    image: ${DOZZLE_IMAGE:-amir20/dozzle:latest}
    environment:
      DOZZLE_NO_ANALYTICS: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    security_opt: ["no-new-privileges:true", "label=disable"]
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:8888:8080"
    mem_limit: 128m

  adminer:
    <<: *service
    profiles: [adminer]
    image: ${ADMINER_IMAGE:-adminer:latest}
    environment:
      ADMINER_DEFAULT_SERVER: postgres
      ADMINER_DESIGN: pepa-linha-dark
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:8082:8080"
    mem_limit: 128m

  phpmyadmin:
    <<: *service
    profiles: [phpmyadmin]
    image: ${PHPMYADMIN_IMAGE:-phpmyadmin:5}
    environment:
      PMA_HOST: mariadb
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:8081:80"
    mem_limit: 256m

  cloudflared:
    <<: *service
    profiles: [cloudflared]
    image: ${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}
    command: tunnel --no-autoupdate run
    environment:
      TUNNEL_TOKEN: ${CF_TUNNEL_TOKEN:-}
    mem_limit: 192m

networks:
  oldbox:
    name: oldbox_net
    external: true

volumes:
  pgdata:
  redisdata:
  mariadbdata:
  mongodata:
  kumadata:
  caddy_data:
  caddy_config:
YAML
}

emit_caddyfile() {
  cat <<EOF
# Managed by OldBox. Edit freely; your changes are never overwritten.
# Apps join the shared Docker network "oldbox_net", so you can reach them by
# container name:   reverse_proxy my-app:3000
# After editing:    docker compose -f $STACK_DIR/compose.yaml exec caddy caddy reload --config /etc/caddy/Caddyfile
EOF
  if [[ $TUNNEL_MODE == direct && -n $DOMAIN ]]; then
    if [[ -n $ACME_EMAIL ]]; then
      printf '\n{\n\temail %s\n}\n' "$ACME_EMAIL"
    fi
    cat <<EOF

$DOMAIN {
	encode zstd gzip
	root * /srv/static
	file_server
}

# app.$DOMAIN {
#	reverse_proxy my-app:3000
# }
EOF
  else
    cat <<'EOF'

{
	# TLS is handled outside (Cloudflare / Tailscale) or not needed on a LAN.
	auto_https off
}

:80 {
	encode zstd gzip
	respond /healthz "ok" 200
	root * /srv/static
	file_server
}

# Route more sites by hostname (map them in Cloudflare to http://caddy:80):
# http://app.example.com {
#	reverse_proxy my-app:3000
# }
#
# PHP site (enable the 'php' component):
# http://php.example.com {
#	root * /srv/php/www
#	php_fastcgi php:9000
#	file_server
# }
EOF
  fi
}

step_stack() {
  local d="$STACK_DIR"
  quiet mkdir -p "$d/caddy" "$d/sites/static" "$d/sites/php/www" "$d/bots"
  emit_compose | sed -e "s/@VERSION@/$OLDBOX_VERSION/" -e "s|@ZRO@|$SEL_RO|g" -e "s|@ZRW@|$SEL_RW|g" \
    | write_managed "$d/compose.yaml" 644
  emit_caddyfile | write_managed "$d/caddy/Caddyfile" 644

  # .env: secrets are generated once and never regenerated
  if (( ! DRY_RUN )); then
    [[ -f $(env_path) ]] || install -m 600 /dev/null "$(env_path)"
    env_set COMPOSE_PROFILES "$(stack_services | tr -s ' ' | sed 's/ $//; s/ /,/g')"
    env_set TZ "$TIMEZONE"
    env_set ADMIN_BIND "$ADMIN_BIND"
    env_set WEB_BIND "$WEB_BIND"
    env_set WEB_HTTP_PORT "$WEB_HTTP_PORT"
    env_set WEB_HTTPS_PORT "$WEB_HTTPS_PORT"
    env_set DOMAIN "$DOMAIN"
    env_set ACME_EMAIL "$ACME_EMAIL"
    if [[ -n $CF_TUNNEL_TOKEN ]]; then env_set CF_TUNNEL_TOKEN "$CF_TUNNEL_TOKEN"; fi
    if [[ -z "$(env_get POSTGRES_USER)" ]]; then env_set POSTGRES_USER postgres; fi
    env_ensure_secret POSTGRES_PASSWORD
    env_ensure_secret REDIS_PASSWORD
    env_ensure_secret MARIADB_ROOT_PASSWORD
    env_ensure_secret MONGO_ROOT_PASSWORD
    msg_ok "Secrets and settings are in $d/.env (readable by its owner only)"
  fi

  if enabled templates; then write_templates; fi
  write_static_site
  if (( ! DRY_RUN )); then
    chown -R "$ADMIN_USER:$(admin_grp)" "$d"
    chmod 600 "$(env_path)"
  fi
}

write_static_site() {
  write_once "$STACK_DIR/sites/static/index.html" 644 <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OldBox is alive</title>
<style>
  :root{color-scheme:dark light;--bg:#0b1020;--fg:#e8ecf8;--a:#00c8ff;--b:#be78ff}
  @media (prefers-color-scheme:light){:root{--bg:#f5f7ff;--fg:#10162b}}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);
       font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;padding:1.5rem;text-align:center}
  h1{font-size:clamp(2rem,9vw,4rem);margin:.2em 0;background:linear-gradient(90deg,var(--a),var(--b),var(--a));
     background-size:200% auto;-webkit-background-clip:text;background-clip:text;color:transparent;animation:flow 6s linear infinite}
  p{opacity:.85;max-width:36rem;margin:0 auto}
  code{background:#8883;padding:.15em .45em;border-radius:.4em}
  .dot{width:.9rem;height:.9rem;border-radius:50%;background:#50fa7b;display:inline-block;margin-right:.5rem;animation:pulse 1.6s ease-in-out infinite}
  @keyframes flow{to{background-position:200% center}}
  @keyframes pulse{50%{transform:scale(1.6);opacity:.4}}
  @media (prefers-reduced-motion:reduce){*{animation:none!important}}
</style>
</head>
<body><main>
  <h1>OldBox is alive</h1>
  <p><span class="dot"></span>Your old laptop is now a home server. Replace <code>sites/static/index.html</code>
     or add your apps to <code>compose.yaml</code>.</p>
</main></body>
</html>
HTML
}

write_templates() {
  local d="$STACK_DIR/bots"
  # ---- Python bot ------------------------------------------------------------
  write_once "$d/python-example/bot.py" 644 <<'PY'
#!/usr/bin/env python3
"""Minimal Telegram bot: long polling, one dependency (requests), graceful shutdown."""
import os
import signal
import sys
import time

import requests

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
if not TOKEN:
    sys.exit("TELEGRAM_BOT_TOKEN is not set (copy .env.example to .env and fill it in)")

API = f"https://api.telegram.org/bot{TOKEN}"
running = True


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def call(method, **params):
    response = requests.post(f"{API}/{method}", json=params, timeout=40)
    response.raise_for_status()
    return response.json()["result"]


print("bot started", flush=True)
offset = None
while running:
    try:
        params = {"timeout": 30}
        if offset:
            params["offset"] = offset
        for update in call("getUpdates", **params):
            offset = update["update_id"] + 1
            message = update.get("message") or {}
            chat_id = (message.get("chat") or {}).get("id")
            text = (message.get("text") or "").strip()
            if not chat_id:
                continue
            if text.startswith("/start"):
                call("sendMessage", chat_id=chat_id, text="Hello! I am running on OldBox.")
            elif text == "/ping":
                call("sendMessage", chat_id=chat_id, text="pong")
    except requests.RequestException as exc:
        print(f"network error: {exc}; retrying in 5s", flush=True)
        time.sleep(5)
print("bot stopped", flush=True)
PY
  write_once "$d/python-example/requirements.txt" 644 <<'TXT'
requests>=2.32
TXT
  write_once "$d/python-example/Dockerfile" 644 <<'DOCKER'
# Tip: pin a version (e.g. python:3.13-slim) once you ship to production.
FROM python:3-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY bot.py .
RUN useradd --system --uid 10001 bot
USER bot
CMD ["python", "bot.py"]
DOCKER
  write_once "$d/python-example/.env.example" 644 <<'ENV'
# Get a token from @BotFather on Telegram, then: cp .env.example .env
TELEGRAM_BOT_TOKEN=
ENV
  write_once "$d/python-example/.dockerignore" 644 <<'IGN'
.env
__pycache__
IGN
  write_once "$d/python-example/compose.yaml" 644 <<'YAML'
# Start:  cp .env.example .env  (add your token)  &&  docker compose up -d --build
# Logs:   docker compose logs -f
name: bot-python-example
services:
  bot:
    build: .
    restart: unless-stopped
    env_file: .env
    mem_limit: 128m
    security_opt: ["no-new-privileges:true"]
    networks: [oldbox]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
networks:
  oldbox:
    name: oldbox_net
    external: true
YAML

  # ---- Node bot --------------------------------------------------------------
  write_once "$d/node-example/bot.js" 644 <<'JS'
// Minimal Telegram bot: long polling, zero dependencies (Node 18+), graceful shutdown.
const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) {
  console.error("TELEGRAM_BOT_TOKEN is not set (copy .env.example to .env and fill it in)");
  process.exit(1);
}
const api = `https://api.telegram.org/bot${token}`;
let running = true;
for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => { running = false; });

async function call(method, params) {
  const res = await fetch(`${api}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(40000),
  });
  const data = await res.json();
  if (!data.ok) throw new Error(data.description || "Telegram API error");
  return data.result;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
  console.log("bot started");
  let offset;
  while (running) {
    try {
      const params = { timeout: 30 };
      if (offset) params.offset = offset;
      for (const update of await call("getUpdates", params)) {
        offset = update.update_id + 1;
        const message = update.message || {};
        const chatId = message.chat && message.chat.id;
        const text = (message.text || "").trim();
        if (!chatId) continue;
        if (text.startsWith("/start")) await call("sendMessage", { chat_id: chatId, text: "Hello! I am running on OldBox." });
        else if (text === "/ping") await call("sendMessage", { chat_id: chatId, text: "pong" });
      }
    } catch (err) {
      console.error(`error: ${err.message}; retrying in 5s`);
      await sleep(5000);
    }
  }
  console.log("bot stopped");
})();
JS
  write_once "$d/node-example/package.json" 644 <<'JSON'
{
  "name": "oldbox-node-bot",
  "version": "1.0.0",
  "private": true,
  "description": "Minimal Telegram bot template for OldBox",
  "main": "bot.js",
  "scripts": { "start": "node bot.js" },
  "engines": { "node": ">=18" }
}
JSON
  write_once "$d/node-example/Dockerfile" 644 <<'DOCKER'
# Tip: pin a version (e.g. node:22-alpine) once you ship to production.
FROM node:lts-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json bot.js ./
USER node
CMD ["node", "bot.js"]
DOCKER
  write_once "$d/node-example/.env.example" 644 <<'ENV'
# Get a token from @BotFather on Telegram, then: cp .env.example .env
TELEGRAM_BOT_TOKEN=
ENV
  write_once "$d/node-example/.dockerignore" 644 <<'IGN'
.env
node_modules
IGN
  write_once "$d/node-example/compose.yaml" 644 <<'YAML'
# Start:  cp .env.example .env  (add your token)  &&  docker compose up -d --build
# Logs:   docker compose logs -f
name: bot-node-example
services:
  bot:
    build: .
    restart: unless-stopped
    env_file: .env
    mem_limit: 128m
    security_opt: ["no-new-privileges:true"]
    networks: [oldbox]
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
networks:
  oldbox:
    name: oldbox_net
    external: true
YAML

  # ---- PHP site --------------------------------------------------------------
  write_once "$STACK_DIR/sites/php/Dockerfile" 644 <<'DOCKER'
FROM php:fpm-alpine
RUN apk add --no-cache postgresql-dev \
 && docker-php-ext-install -j"$(nproc)" pdo_pgsql pdo_mysql mysqli
DOCKER
  write_once "$STACK_DIR/sites/php/www/index.php" 644 <<'PHP'
<?php
header('Content-Type: text/html; charset=utf-8');
$h = fn(string $s): string => htmlspecialchars($s, ENT_QUOTES);
?>
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PHP on OldBox</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem}</style>
<h1>PHP <?= $h(PHP_VERSION) ?> is running on OldBox</h1>
<p>Extensions: <?= $h(implode(', ', ['pdo_pgsql', 'pdo_mysql', 'mysqli'])) ?></p>
<p>Edit <code>sites/php/www/index.php</code> and refresh.</p>
PHP
}

step_launch() {
  local d="$STACK_DIR"
  local -a dc=(docker compose --project-directory "$d")
  run "Validating the compose file" "${dc[@]}" config -q || die "compose.yaml is not valid." "Open $d/compose.yaml and check the highlighted problem in $LOG_FILE."
  run "Pulling container images (the first run downloads a few hundred MB)" retry 3 "${dc[@]}" pull --quiet --ignore-buildable \
    || run_try "Pulling container images (compatibility mode)" retry 3 "${dc[@]}" pull --quiet \
    || die "Could not download container images." "Check your connection and Docker Hub access, then re-run."
  if ! run_try "Starting services and waiting until they are healthy" "${dc[@]}" up -d --build --wait --wait-timeout 300 --remove-orphans; then
    run "Starting services" "${dc[@]}" up -d --build --remove-orphans \
      || die "A service failed to start." "See which one: docker compose --project-directory $d ps    Logs: docker compose --project-directory $d logs --tail 50"
  fi
  if (( ! DRY_RUN )); then
    local running
    running=$("${dc[@]}" ps --services --status running 2>/dev/null | tr '\n' ' ' || true)
    msg_ok "Running now: ${running:-none (check: docker compose ps)}"
  fi
}

emit_backup_script() {
  cat <<'BASH'
#!/usr/bin/env bash
# OldBox nightly backup. Managed by OldBox; started by oldbox-backup.timer.
# shellcheck disable=SC2317  # the dump_* functions are called indirectly through job()
set -Eeuo pipefail
umask 077
STACK_DIR=/opt/oldbox BACKUP_DIR=/var/backups/oldbox KEEP_DAYS=7 REMOTE=""
# shellcheck disable=SC1091
if [ -r /etc/oldbox/backup.conf ]; then . /etc/oldbox/backup.conf; fi

dc() { docker compose --project-directory "$STACK_DIR" "$@"; }
running() { [ -n "$(dc ps -q "$1" 2>/dev/null)" ]; }
say() { echo "$*"; logger -t oldbox-backup -- "$*" 2>/dev/null || true; }

ts=$(date +%Y%m%d-%H%M%S)
dest="$BACKUP_DIR/$ts"
mkdir -p "$dest"
chmod 700 "$dest"
fail=0

# job NAME FUNCTION  -> runs FUNCTION, records success or failure
job() { if "$2"; then say "$1 ok"; else say "$1 FAILED"; fail=1; fi; }

# The single quotes are intentional: variables must expand inside the container.
# shellcheck disable=SC2016
dump_postgres() { dc exec -T postgres sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip -9 >"$dest/postgres.sql.gz"; }
# shellcheck disable=SC2016
dump_mariadb()  { dc exec -T mariadb sh -c 'mariadb-dump --all-databases -uroot -p"$MARIADB_ROOT_PASSWORD"' | gzip -9 >"$dest/mariadb.sql.gz"; }
# shellcheck disable=SC2016
dump_mongo()    { dc exec -T mongo sh -c 'mongodump --archive --gzip -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' >"$dest/mongo.archive.gz"; }
dump_redis()    { dc exec -T redis redis-cli SAVE >/dev/null && dc cp redis:/data/dump.rdb "$dest/redis-dump.rdb" >/dev/null 2>&1; }
dump_kuma()     { dc exec -T kuma tar czf - -C /app/data . >"$dest/uptime-kuma-data.tgz"; }
dump_config()   { tar czf "$dest/stack-config.tgz" -C "$STACK_DIR" .; }
sync_remote()   { rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" "$BACKUP_DIR"/ "$REMOTE"/; }

if running postgres; then job postgres dump_postgres; fi
if running mariadb;  then job mariadb dump_mariadb; fi
if running mongo;    then job mongo dump_mongo; fi
if running redis;    then job redis dump_redis; fi
if running kuma;     then job kuma dump_kuma; fi
job "stack config" dump_config

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true

if [ -n "$REMOTE" ]; then job "remote copy" sync_remote; fi
say "backup finished in $dest (failures: $fail)"
exit "$fail"
BASH
}

step_backups() {
  run_opt "Making sure rsync is available" pm_install_each rsync
  write_managed /etc/oldbox/backup.conf 600 force <<EOF
# Managed by OldBox
STACK_DIR=$STACK_DIR
BACKUP_DIR=/var/backups/oldbox
KEEP_DAYS=$BACKUP_KEEP_DAYS
REMOTE="$BACKUP_REMOTE"
EOF
  emit_backup_script | write_managed /usr/local/sbin/oldbox-backup 755 force
  write_managed /etc/systemd/system/oldbox-backup.service 644 <<'EOF'
# Managed by OldBox
[Unit]
Description=OldBox nightly backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/oldbox-backup
Nice=10
IOSchedulingClass=idle
EOF
  write_managed /etc/systemd/system/oldbox-backup.timer 644 <<EOF
# Managed by OldBox
[Unit]
Description=Run the OldBox backup every night

[Timer]
OnCalendar=*-*-* ${BACKUP_TIME}:00
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  quiet systemctl daemon-reload
  run "Scheduling nightly backups at $BACKUP_TIME" systemctl enable --now oldbox-backup.timer || msg_warn "Could not enable the backup timer."
  quiet install -d -m 700 /var/backups/oldbox
}

step_finish() {
  if [[ -f $SELF_PATH ]] && (( ! DRY_RUN )); then
    if [[ ! -e /usr/local/bin/oldbox ]] || ! cmp -s "$SELF_PATH" /usr/local/bin/oldbox; then
      install -m 0755 "$SELF_PATH" /usr/local/bin/oldbox
      msg_ok "Installed the 'oldbox' command (try: oldbox status)"
    fi
  fi
  save_answers
}

# =============================================================================
# 9. Commands
# =============================================================================
primary_ip() { hostname -I 2>/dev/null | awk '{print $1}' || true; }

summary() {
  local ip took d="$STACK_DIR" svc fwd="" ui="" w
  ip=$(primary_ip); ip=${ip:-<this-machine>}
  took=$(( SECONDS - START_SECONDS ))
  svc=$(stack_services)
  printf '\n'; hr
  if (( DRY_RUN )); then
    printf '  %sDry run complete: nothing was changed.%s\n' "$C_BOLD$C_OK" "$C_RESET"
  else
    printf '  %sOldBox is ready.%s\n' "$C_BOLD$C_OK" "$C_RESET"
  fi
  printf '  %sFinished in %ss%s\n\n' "$C_MUTED" "$took" "$C_RESET"
  rail_kv "$C_ACCENT" "Connect from PC" "ssh ${ADMIN_USER}@${ip}"
  if [[ -n $svc ]]; then
    if enabled kuma;       then fwd+=" -L 3001:127.0.0.1:3001"; ui+="http://localhost:3001 (Uptime Kuma)  "; fi
    if enabled dozzle;     then fwd+=" -L 8888:127.0.0.1:8888"; ui+="http://localhost:8888 (logs)  "; fi
    if enabled adminer;    then fwd+=" -L 8082:127.0.0.1:8082"; ui+="http://localhost:8082 (Adminer)  "; fi
    if enabled phpmyadmin; then fwd+=" -L 8081:127.0.0.1:8081"; ui+="http://localhost:8081 (phpMyAdmin)  "; fi
    if enabled postgres;   then fwd+=" -L 5432:127.0.0.1:5432"; fi
    rail_kv "$C_ACCENT" "Stack folder" "$d   (secrets: $d/.env)"
    rail_kv "$C_ACCENT" "Services" "$svc"
    if [[ -n $fwd ]]; then
      rail_kv "$C_ACCENT" "Admin UIs" "one SSH tunnel from your PC:  ssh${fwd} ${ADMIN_USER}@${ip}"
      if [[ -n $ui ]]; then rail_kv "$C_ACCENT" "" "then open: $ui"; fi
    fi
  fi
  case $TUNNEL_MODE in
    lan)        rail_kv "$C_INFO" "Web (LAN)" "http://${ip}:${WEB_HTTP_PORT}" ;;
    tailscale)  rail_kv "$C_INFO" "Public HTTPS" "sudo tailscale up   then   sudo tailscale funnel --bg ${WEB_HTTP_PORT}" ;;
    cloudflare) rail_kv "$C_INFO" "Cloudflare" "map your public hostname to  http://caddy:80  in the dashboard" ;;
    direct)     rail_kv "$C_INFO" "Direct" "forward router ports 80+443 to ${ip}; point DNS for ${DOMAIN} at your public IP" ;;
  esac
  if enabled tailscale && [[ $TUNNEL_MODE != tailscale ]]; then
    rail_kv "$C_INFO" "Remote access" "sudo tailscale up   (open the link it prints)"
  fi
  if enabled templates; then rail_kv "$C_INFO" "Bot templates" "$d/bots/python-example  and  $d/bots/node-example"; fi
  printf '\n'
  rail "$C_WARN" "Next: log out and back in once (docker group), test SSH from a NEW terminal, then reboot when convenient."
  if (( ${#WARNINGS[@]} > 0 )); then
    printf '\n  %s%d note(s) worth a look:%s\n' "$C_WARN" "${#WARNINGS[@]}" "$C_RESET"
    for w in "${WARNINGS[@]}"; do emit "$S_WARN" "$C_WARN" "$w"; done
  fi
  printf '\n  %sLog: %s   |   Health: oldbox status   |   Update: oldbox update%s\n\n' "$C_MUTED" "$LOG_FILE" "$C_RESET"
}

need_root() {
  if (( EUID == 0 )); then return 0; fi
  if (( DRY_RUN )) || [[ $COMMAND == check || $COMMAND == status ]]; then return 0; fi
  if command -v sudo >/dev/null 2>&1 && [[ -f ${SELF_PATH:-} ]]; then
    printf 'OldBox needs root; re-running with sudo...\n' >&2
    exec sudo -E bash "$SELF_PATH" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
  die "OldBox needs root privileges." "Run:  sudo ./oldbox.sh    (or become root first with: su -)"
}

setup_runtime() {
  TMP_DIR=$(mktemp -d)
  if (( EUID != 0 )); then LOG_FILE="/tmp/oldbox-$(id -un).log"; fi
  if (( EUID == 0 && ! DRY_RUN )); then
    mkdir -p "$STATE_DIR" "$CONF_DIR"; chmod 700 "$STATE_DIR"
    : >>"$LOG_FILE"; chmod 640 "$LOG_FILE"
  fi
  if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
  log_raw "==== oldbox $OLDBOX_VERSION  command=$COMMAND dry_run=$DRY_RUN user=$(id -un) ===="
}

cmd_install() {
  need_root
  setup_runtime
  detect_os
  load_answers
  apply_defaults
  wizard
  if ! can_prompt; then banner; fi
  normalize_selection
  validate_inputs
  preflight
  show_plan
  if can_prompt && ! confirm "Proceed with these settings?" y; then
    msg_info "Cancelled. Nothing was changed."; return 0
  fi
  if (( EUID == 0 && ! DRY_RUN )); then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another OldBox run is already in progress." "Wait for it to finish (or check: ps aux | grep oldbox)."
  fi
  STARTED=1
  plan_steps
  local s id title
  for s in "${STEPS[@]}"; do
    id=${s%%|*}; title=${s#*|}
    step "$title"
    "step_$id"
  done
  summary
}

cmd_check() {
  setup_runtime; detect_os; load_answers; apply_defaults
  banner; normalize_selection
  validate_inputs
  preflight
  show_plan
  printf '\n'; emit "$S_OK" "$C_OK" "All checks passed. Run without 'check' to install."
}

cmd_status() {
  setup_runtime; detect_os; load_answers; apply_defaults
  banner
  section "System"
  kv "Host" "$(hostname) ($(primary_ip))"
  kv "OS" "$OS_NAME"
  kv "Uptime" "$(uptime -p 2>/dev/null | sed 's/^up //')"
  kv "Load" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  kv "Memory" "$(free -m 2>/dev/null | awk '/^Mem:/{printf "%d / %d MB (%d%%)", $3, $2, $3*100/$2}')"
  kv "Disk /" "$(df -h / 2>/dev/null | awk 'NR==2{printf "%s used of %s (%s)", $3, $2, $5}')"
  local t max=0
  for t in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r $t ]] || continue
    if (( $(cat "$t") > max )); then max=$(cat "$t"); fi
  done
  if (( max > 0 )); then kv "Temperature" "$(( max / 1000 )) C"; fi
  local b
  for b in /sys/class/power_supply/BAT*; do
    [[ -r $b/capacity ]] || continue
    kv "Battery" "$(cat "$b/capacity")%  ($(cat "$b/status" 2>/dev/null))"
  done
  if command -v tailscale >/dev/null 2>&1; then kv "Tailscale" "$(tailscale ip -4 2>/dev/null | head -n1 || echo 'not connected')"; fi
  if command -v docker >/dev/null 2>&1; then
    section "Containers"
    local name stat col sym
    if docker ps -a --format '{{.Names}}|{{.Status}}' >"$TMP_DIR/ps" 2>/dev/null && [[ -s $TMP_DIR/ps ]]; then
      while IFS='|' read -r name stat; do
        col=$C_OK; sym=$S_OK
        case $stat in *nhealthy*|Exited*|Restarting*) col=$C_ERR; sym=$S_ERR ;; esac
        printf '  %s%s%s %-18s %s\n' "$col" "$sym" "$C_RESET" "$(trunc "$name" 18)" "$(trunc "$stat" $(( W - 26 )))"
      done <"$TMP_DIR/ps"
    else msg_dim "No containers (or no permission: try with sudo)."; fi
  fi
  printf '\n'
}

cmd_update() {
  need_root; setup_runtime; detect_os; load_answers; apply_defaults
  banner
  [[ -f $STACK_DIR/compose.yaml ]] || die "No stack found in $STACK_DIR." "Run the installer first, or pass --stack-dir."
  local -a dc=(docker compose --project-directory "$STACK_DIR")
  STEP_TOTAL=3
  step "Pulling newer images";        run "Downloading updates" retry 2 "${dc[@]}" pull --quiet --ignore-buildable || die "Pull failed."
  step "Recreating changed services"; run "Applying updates" "${dc[@]}" up -d --build --wait --wait-timeout 300 --remove-orphans || die "Some services failed to start." "docker compose --project-directory $STACK_DIR ps"
  step "Cleaning up";                 run_opt "Removing unused images" docker image prune -f
  printf '\n'; emit "$S_OK" "$C_OK" "Stack is up to date."
}

cmd_backup() {
  need_root; setup_runtime; banner
  [[ -x /usr/local/sbin/oldbox-backup ]] || die "Backups are not installed." "Re-run the installer with the 'backups' component enabled."
  STEP_TOTAL=1; step "Running the backup now"
  run "Backing up databases and configuration" /usr/local/sbin/oldbox-backup || die "Backup finished with errors." "journalctl -t oldbox-backup"
  emit "$S_INFO" "$C_INFO" "Backups are stored in /var/backups/oldbox"
}

main() {
  parse_args "$@"
  mark_env_explicit
  ui_init
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap cleanup EXIT
  trap on_signal INT TERM
  case $COMMAND in
    help)    usage ;;
    install) cmd_install ;;
    check)   cmd_check ;;
    status)  cmd_status ;;
    update)  cmd_update ;;
    backup)  cmd_backup ;;
  esac
}

main "$@"
