#!/usr/bin/env bash
#
# uninstall.sh — undo everything this repo changed.
#
# WHAT IT REVERSES
#   1. The OnlyOffice launcher override in ~/.local/share/applications
#      Deleting it makes the system launcher take over again, which is the original state.
#   2. The LibreOffice Skia settings, restored from the timestamped backup taken before
#      they were written.
#   3. The Dolphin thumbnail cap, restored from its backup.
#   4. File associations, restored from mime_defaults.backup -- the record of what the
#      handlers were BEFORE step 04 first ran.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It does not uninstall packages. Removing software is a bigger decision than reverting a
#   setting, other things may now depend on those packages, and on a shared machine someone
#   else may be using them. The exact pacman command is PRINTED for you to run if you want
#   it -- never executed.
#
#   It also cannot bring back processes that step 01 killed. Nothing can; they were leaked
#   processes holding documents that had been open for days.
#
# Usage:
#   ./uninstall.sh              # dry run: show what would be restored
#   ./uninstall.sh --apply      # restore
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/steps/_common.sh"

print_usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }
parse_common_flags "$@"

heading "Undo — restore the settings this repo changed"
print_machine_line
announce_mode

# ── 1. OnlyOffice launcher override ────────────────────────────────────────────
heading "1. OnlyOffice launcher override"
OO_OVERRIDE="$HOME/.local/share/applications/onlyoffice-desktopeditors.desktop"
if [ -f "$OO_OVERRIDE" ]; then
    info "removing $OO_OVERRIDE (the system launcher takes over again)"
    run rm -f "$OO_OVERRIDE"
    have_cmd update-desktop-database && \
        run update-desktop-database "$HOME/.local/share/applications"
else
    ok "no override present — nothing to undo"
fi

# ── 2 & 3. Restore the most recent backup of each config file ──────────────────
# Backups are named <file>.bak.<UTC timestamp>, so the newest sorts last.
restore_newest_backup() {
    local target="$1" label="$2"
    local newest
    newest=$(ls -1 "${target}".bak.* 2>/dev/null | sort | tail -1)
    if [ -z "$newest" ]; then
        ok "$label: no backup found — it was never modified by this repo"
        return
    fi
    info "$label: restoring from $(basename "$newest")"
    run cp -a "$newest" "$target"
}

heading "2. LibreOffice profile"
LO_PROFILE="$HOME/.config/libreoffice/4/user/registrymodifications.xcu"
if pgrep -x soffice.bin >/dev/null 2>&1; then
    fail "LibreOffice is running — close it first or it will rewrite the profile on exit"
else
    restore_newest_backup "$LO_PROFILE" "LibreOffice profile"
fi

heading "3. Dolphin thumbnail cap"
restore_newest_backup "$HOME/.config/dolphinrc" "dolphinrc"

# ── 4. File associations ───────────────────────────────────────────────────────
heading "4. File associations"
BACKUP="$REPO_ROOT/mime_defaults.backup"
if [ ! -f "$BACKUP" ]; then
    ok "no mime_defaults.backup — associations were never changed by this repo"
else
    while IFS='=' read -r mime handler; do
        [ -z "$mime" ] && continue
        if [ -z "$handler" ]; then
            # There was no handler originally. xdg-mime cannot unset one, so say so plainly
            # rather than pretending it was restored.
            warn "$mime originally had NO handler; xdg-mime cannot unset it — leaving as is"
            continue
        fi
        cur="$(xdg-mime query default "$mime" 2>/dev/null)"
        if [ "$cur" = "$handler" ]; then
            ok "$mime already -> $handler"
        else
            info "$mime: $cur -> $handler"
            run xdg-mime default "$handler" "$mime"
        fi
    done < "$BACKUP"
fi

# ── Packages: print, never run ─────────────────────────────────────────────────
heading "5. Packages (not removed automatically)"
INSTALLED=()
for p in ark imv libreoffice-fresh qimgv vipsdisp nomacs wps-office freeoffice; do
    pkg_installed "$p" && INSTALLED+=("$p")
done
if [ "${#INSTALLED[@]}" -eq 0 ]; then
    ok "none of this repo's packages are installed"
else
    info "these packages are installed; remove them yourself if you want them gone:"
    printf '\n    sudo pacman -Rns %s\n\n' "${INSTALLED[*]}"
    warn "check nothing else needs them first — this is deliberately not automated"
fi

heading "Done"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "DRY RUN — nothing was restored. Re-run with --apply."
else
    ok "settings restored"
    info "fully quit and reopen the applications for the original behaviour to return"
fi
