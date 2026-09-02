#!/usr/bin/env bash
#
# _common.sh — shared detection + dry-run helpers for the gui-speedup scripts.
#
# NOT MEANT TO BE RUN DIRECTLY. Every other script in this repo sources it:
#     source "$(dirname "$0")/_common.sh"
#
# WHY THIS FILE EXISTS
#   These scripts are meant to run on any machine in the lab, not just the one they were
#   written on. That machine was Arch Linux + KDE Plasma 6 + X11 + an NVIDIA GTX 1080, but
#   the other boxes may have a different GPU, a different desktop, or a different distro.
#   Rather than assume, every script asks this file what it is running on and skips the
#   steps that do not apply. A skipped step prints WHY it was skipped -- silence would be
#   indistinguishable from a bug.
#
# THE DRY-RUN CONTRACT
#   Every script that changes anything defaults to DRY-RUN and only acts with --apply.
#   This mirrors clean_feat_reruns.sh in the parent code tree, which is dry-run until you
#   pass --delete. Scripts route EVERY mutating command through run(), so dry-run mode is
#   a property of this file rather than something each script has to remember.

# Guard against being executed instead of sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "_common.sh is a library; source it, do not run it." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────
# Colour only when stdout is a terminal, so redirecting to a log file gives clean text
# instead of escape-code soup.
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m';  C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

ok()      { printf '%s  PASS %s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()    { printf '%s  WARN %s %s\n' "$C_YEL" "$C_OFF" "$*"; }
fail()    { printf '%s  FAIL %s %s\n' "$C_RED" "$C_OFF" "$*"; }
info()    { printf '%s  ---- %s %s\n' "$C_DIM" "$C_OFF" "$*"; }
skip()    { printf '%s  SKIP %s %s\n' "$C_BLU" "$C_OFF" "$*"; }
heading() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

# A step that cannot apply here. Always explains itself.
skip_step() { skip "$1"; return 0; }

# ─────────────────────────────────────────────────────────────────────────────
# Dry-run plumbing
# ─────────────────────────────────────────────────────────────────────────────
# DRY_RUN=1 is the default. Scripts flip it to 0 only when the user passes --apply.
DRY_RUN="${DRY_RUN:-1}"

# run <command...> — the only way these scripts are allowed to change anything.
#   dry-run : prints the command, prefixed "would:", and returns success
#   apply   : prints the command, prefixed "run:", then actually executes it
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s  would: %s%s\n' "$C_DIM" "$*" "$C_OFF"
        return 0
    fi
    printf '%s  run:   %s%s\n' "$C_DIM" "$*" "$C_OFF"
    "$@"
}

# run_sh <shell-string> — same contract, for the rare command that genuinely needs a shell
# (redirection or a pipe). Kept separate so that plain run() never invokes a shell and so
# never has to think about quoting.
run_sh() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s  would: %s%s\n' "$C_DIM" "$1" "$C_OFF"
        return 0
    fi
    printf '%s  run:   %s%s\n' "$C_DIM" "$1" "$C_OFF"
    bash -c "$1"
}

# Standard flag parsing. Scripts call: parse_common_flags "$@"
# Sets DRY_RUN, and leaves anything it does not recognise in REMAINING_ARGS for the caller.
REMAINING_ARGS=()
parse_common_flags() {
    REMAINING_ARGS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply)   DRY_RUN=0 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help) print_usage; exit 0 ;;
            *)         REMAINING_ARGS+=("$1") ;;
        esac
        shift
    done
}

# Printed at the top of every mutating script so the mode is never ambiguous.
announce_mode() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\n%sDRY RUN%s - nothing will be changed. Re-run with %s--apply%s to act.\n' \
               "$C_YEL$C_BLD" "$C_OFF" "$C_BLD" "$C_OFF"
    else
        printf '\n%sAPPLY MODE%s - changes will be made.\n' "$C_GRN$C_BLD" "$C_OFF"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Detection
# ─────────────────────────────────────────────────────────────────────────────

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# detect_distro -> the ID field from /etc/os-release ("arch", "ubuntu", "fedora", ...)
detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${ID:-unknown}" )
    else
        printf 'unknown'
    fi
}

# detect_gpu_vendor -> nvidia | amd | intel | none
# Reads the kernel driver actually bound to the VGA/3D device, not just the chip name.
# The bound driver is what matters: an NVIDIA card running nouveau behaves differently from
# one running the proprietary module, and the GPU flags we set differ accordingly.
detect_gpu_vendor() {
    local line
    line=$(lspci -k 2>/dev/null | grep -A3 -iE 'vga compatible|3d controller' || true)
    if printf '%s' "$line" | grep -qi 'Kernel driver in use: nvidia'; then
        printf 'nvidia'
    elif printf '%s' "$line" | grep -qiE 'Kernel driver in use: (amdgpu|radeon)'; then
        printf 'amd'
    elif printf '%s' "$line" | grep -qiE 'Kernel driver in use: (i915|xe)'; then
        printf 'intel'
    elif printf '%s' "$line" | grep -qi 'Kernel driver in use: nouveau'; then
        printf 'nouveau'
    else
        printf 'none'
    fi
}

# detect_de -> kde | gnome | xfce | other | none
detect_de() {
    local d="${XDG_CURRENT_DESKTOP:-}"
    # Over SSH this is often empty even though a desktop is running on the console, so
    # fall back to looking for the window manager process.
    if [ -z "$d" ]; then
        if   pgrep -x kwin_x11 >/dev/null 2>&1 || pgrep -x kwin_wayland >/dev/null 2>&1; then d=KDE
        elif pgrep -x gnome-shell >/dev/null 2>&1; then d=GNOME
        elif pgrep -x xfwm4      >/dev/null 2>&1; then d=XFCE
        fi
    fi
    case "${d^^}" in
        *KDE*|*PLASMA*) printf 'kde' ;;
        *GNOME*)        printf 'gnome' ;;
        *XFCE*)         printf 'xfce' ;;
        '')             printf 'none' ;;
        *)              printf 'other' ;;
    esac
}

# have_root -> 0 if we can gain root non-interactively or already are
# Note: this returns failure when sudo would merely PROMPT for a password. That is
# deliberate for the check script (it must never block), but the install script treats a
# prompt as fine, since a human is sitting there.
have_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    have_cmd sudo && sudo -n true 2>/dev/null
}

# sudo_available -> 0 if sudo exists at all (may prompt for a password)
sudo_available() { [ "$(id -u)" -eq 0 ] || have_cmd sudo; }

# SUDO — prefix for commands needing root. Empty when already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# pkg_installed <name> — distro-aware "is this package present?"
pkg_installed() {
    case "$(detect_distro)" in
        arch|manjaro|endeavouros|cachyos) pacman -Qq "$1" >/dev/null 2>&1 ;;
        debian|ubuntu|pop|linuxmint)      dpkg -s "$1"   >/dev/null 2>&1 ;;
        fedora|rhel|centos|rocky|alma)    rpm -q "$1"    >/dev/null 2>&1 ;;
        *)                                return 1 ;;
    esac
}

# aur_helper -> prints yay/paru if one exists, else empty
aur_helper() {
    if   have_cmd yay;  then printf 'yay'
    elif have_cmd paru; then printf 'paru'
    fi
}

# is_arch — the install step only knows how to install on Arch-family distros.
is_arch() {
    case "$(detect_distro)" in
        arch|manjaro|endeavouros|cachyos) return 0 ;;
        *) return 1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Backups
# ─────────────────────────────────────────────────────────────────────────────
# Every file this repo edits is backed up first, with a UTC timestamp, so uninstall.sh
# has something exact to restore. Backups live beside the original.
BACKUP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

backup_file() {
    local f="$1"
    [ -e "$f" ] || { info "no existing $f to back up"; return 0; }
    run cp -a "$f" "${f}.bak.${BACKUP_STAMP}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
# Mirrors run_pipeline.sh: everything is tee'd to logs/<name>_<UTC>.log so there is a
# record of what a given run actually did.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

start_log() {
    local name="$1"
    mkdir -p "$REPO_ROOT/logs"
    LOG_FILE="$REPO_ROOT/logs/${name}_${BACKUP_STAMP}.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "log: $LOG_FILE"
}

# One-line summary of the machine, printed by every script so a pasted log is diagnosable.
print_machine_line() {
    info "host=$(hostname)  distro=$(detect_distro)  gpu=$(detect_gpu_vendor)  de=$(detect_de)  user=$(id -un)"
}
