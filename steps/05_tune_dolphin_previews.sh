#!/usr/bin/env bash
#
# 05_tune_dolphin_previews.sh — stop the file manager decoding enormous images for icons.
#
# WHY
#   To draw a thumbnail, a file manager has to fully decode the image first -- there is no
#   shortcut, because the small preview is made by shrinking the full-size picture. With no
#   size limit configured, browsing a folder of very large figures makes Dolphin decode
#   every one of them just to paint icons a couple of centimetres wide. The folder appears
#   to freeze, and the work is thrown away as soon as you scroll.
#
#   A size cap fixes this completely. Files above the cap get a generic type icon instead of
#   a preview, which costs nothing and is all you need to see what is in the folder.
#
# WHY 5 MB BY DEFAULT
#   Comfortably above ordinary screenshots and photos, so everyday previews still work, and
#   far below the scientific figures that cause the stall. Change it with --size.
#
# SCOPE
#   KDE / Dolphin only. Other desktops handle thumbnail limits differently and are skipped.
#   The setting is MaximumSize under [PreviewSettings] in ~/.config/dolphinrc, stored in
#   bytes -- this script does the megabyte conversion for you.
#
# Usage:
#   ./05_tune_dolphin_previews.sh                # dry run, would set 5 MB
#   ./05_tune_dolphin_previews.sh --apply        # set the 5 MB cap
#   ./05_tune_dolphin_previews.sh --size 20 --apply   # 20 MB cap instead
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

print_usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

SIZE_MB=5
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --size) SIZE_MB="${2:-5}"; shift ;;
        *)      ARGS+=("$1") ;;
    esac
    shift
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

heading "Step 5 — cap file-manager thumbnail size"
print_machine_line
announce_mode

DE="$(detect_de)"
if [ "$DE" != "kde" ]; then
    skip_step "this step is KDE/Dolphin-specific (detected desktop: $DE)"
    exit 0
fi
if ! have_cmd dolphin; then
    skip_step "Dolphin is not installed"
    exit 0
fi

DRC="$HOME/.config/dolphinrc"
SIZE_BYTES=$((SIZE_MB * 1024 * 1024))

CURRENT=$(sed -n '/^\[PreviewSettings\]/,/^\[/p' "$DRC" 2>/dev/null \
          | grep -m1 '^MaximumSize=' | cut -d= -f2)
if [ -n "$CURRENT" ]; then
    info "current cap: $((CURRENT / 1024 / 1024)) MB"
else
    info "current cap: none (Dolphin will attempt to preview files of any size)"
fi
info "new cap: ${SIZE_MB} MB (${SIZE_BYTES} bytes)"

if [ "$CURRENT" = "$SIZE_BYTES" ]; then
    ok "already set to ${SIZE_MB} MB — nothing to do"
    exit 0
fi

[ -f "$DRC" ] && backup_file "$DRC"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s  would: set MaximumSize=%s under [PreviewSettings] in %s%s\n' \
           "$C_DIM" "$SIZE_BYTES" "$DRC" "$C_OFF"
    warn "DRY RUN — nothing was changed. Re-run with --apply."
    exit 0
fi

# kwriteconfig is KDE's own tool for this and handles creating the file and the section
# correctly. Prefer it; fall back to editing the INI by hand only if it is unavailable.
KW=""
for c in kwriteconfig6 kwriteconfig5; do have_cmd "$c" && { KW="$c"; break; }; done

if [ -n "$KW" ]; then
    run "$KW" --file dolphinrc --group PreviewSettings --key MaximumSize "$SIZE_BYTES"
    ok "set via $KW"
else
    info "kwriteconfig not found — editing dolphinrc directly"
    if grep -q '^\[PreviewSettings\]' "$DRC" 2>/dev/null; then
        if grep -q '^MaximumSize=' "$DRC"; then
            sed -i "s/^MaximumSize=.*/MaximumSize=$SIZE_BYTES/" "$DRC"
        else
            sed -i "/^\[PreviewSettings\]/a MaximumSize=$SIZE_BYTES" "$DRC"
        fi
    else
        printf '\n[PreviewSettings]\nMaximumSize=%s\n' "$SIZE_BYTES" >> "$DRC"
    fi
    ok "wrote MaximumSize=$SIZE_BYTES to $DRC"
fi

info "restart Dolphin for this to take effect (close all windows, or: killall dolphin)"
info "you can also set this in Dolphin: Settings > Configure Dolphin > General > Previews"
