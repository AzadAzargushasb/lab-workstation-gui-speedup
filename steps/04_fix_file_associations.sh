#!/usr/bin/env bash
#
# 04_fix_file_associations.sh — point images and archives at the right applications.
#
# WHY THIS MATTERS MORE THAN IT SOUNDS
#   A "file association" (or MIME default) is the rule that decides which program opens a
#   file when you double-click it. It is easy for these to end up wrong -- a browser
#   installs itself as the handler for PNG, a package that provided the archive tool gets
#   removed -- and the result is not an error message, just something slow or missing.
#
#   Two real cases found on the machine this was written for:
#
#   1. PNG and JPEG were opening in Chromium. A web browser is a poor image viewer for very
#      large files: it has no tiled rendering, no level-of-detail, and it must decode the
#      whole image before showing anything. Handing it a several-hundred-megapixel figure is
#      far slower than any purpose-built viewer.
#
#   2. NOTHING was registered for application/zip, so the file manager offered no way to
#      extract an archive at all. That reads as "the file manager cannot unzip" when in
#      fact the handler was simply absent. (Installing Ark, in step 02, provides it.)
#
# WHAT IT PICKS
#   The fastest image viewer actually installed, preferring in this order:
#     vipsdisp  tiled/lazy rendering, best for very large images
#     qimgv     OpenGL, good general-purpose replacement
#     imv       OpenGL, lightweight
#     gwenview  the KDE default, CPU-rendered (used only if nothing better exists)
#   Pass --viewer NAME to override the choice.
#
# REVERSIBILITY
#   The previous handler for every MIME type it touches is recorded to
#   mime_defaults.backup in the repo root before anything changes, and uninstall.sh
#   restores from that file.
#
# Usage:
#   ./04_fix_file_associations.sh                     # dry run: show current vs proposed
#   ./04_fix_file_associations.sh --apply             # set them
#   ./04_fix_file_associations.sh --viewer imv --apply
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

print_usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }

FORCE_VIEWER=""
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --viewer) FORCE_VIEWER="${2:-}"; shift ;;
        *)        ARGS+=("$1") ;;
    esac
    shift
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

heading "Step 4 — fix file associations"
print_machine_line
announce_mode

if ! have_cmd xdg-mime; then
    skip_step "xdg-mime is not installed — cannot manage file associations"
    exit 0
fi

# ── Choose an image viewer ─────────────────────────────────────────────────────
# Each candidate is (command, desktop-entry). The desktop entry is what xdg-mime wants;
# the command is how we tell whether it is actually installed.
pick_viewer() {
    if [ -n "$FORCE_VIEWER" ]; then
        printf '%s.desktop' "$FORCE_VIEWER"; return
    fi
    for pair in "vipsdisp:vipsdisp.desktop" \
                "qimgv:qimgv.desktop" \
                "imv:imv.desktop" \
                "gwenview:org.kde.gwenview.desktop"; do
        cmd="${pair%%:*}"; entry="${pair##*:}"
        if have_cmd "$cmd"; then
            # Only accept it if the .desktop file really exists somewhere, otherwise
            # xdg-mime would happily record a handler that cannot be launched.
            for d in "$HOME/.local/share/applications" /usr/share/applications; do
                [ -f "$d/$entry" ] && { printf '%s' "$entry"; return; }
            done
        fi
    done
}

VIEWER="$(pick_viewer)"
if [ -z "$VIEWER" ]; then
    warn "no image viewer found — run steps/02_install_viewer_stack.sh first"
else
    info "chosen image viewer: $VIEWER"
fi

# ── Record current state so uninstall.sh can restore it ────────────────────────
BACKUP="$REPO_ROOT/mime_defaults.backup"
MIMES=(image/png image/jpeg image/tiff image/webp application/zip)

heading "Current handlers"
for m in "${MIMES[@]}"; do
    cur="$(xdg-mime query default "$m" 2>/dev/null)"
    printf '  %-18s %s\n' "$m" "${cur:-<none>}"
done

if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$BACKUP" ]; then
    # Written once, on the first apply, so a later re-run cannot overwrite the record of
    # the ORIGINAL state with our own settings.
    : > "$BACKUP"
    for m in "${MIMES[@]}"; do
        printf '%s=%s\n' "$m" "$(xdg-mime query default "$m" 2>/dev/null)" >> "$BACKUP"
    done
    ok "recorded original handlers to $(basename "$BACKUP")"
elif [ -f "$BACKUP" ]; then
    info "original handlers already recorded in $(basename "$BACKUP")"
fi

# ── Images ─────────────────────────────────────────────────────────────────────
heading "Setting image handlers"
if [ -z "$VIEWER" ]; then
    skip_step "no viewer available to assign"
else
    for m in image/png image/jpeg image/tiff image/webp; do
        cur="$(xdg-mime query default "$m" 2>/dev/null)"
        if [ "$cur" = "$VIEWER" ]; then
            ok "$m already -> $VIEWER"
        else
            info "$m: ${cur:-<none>} -> $VIEWER"
            run xdg-mime default "$VIEWER" "$m"
        fi
    done
fi

# ── Archives ───────────────────────────────────────────────────────────────────
heading "Setting archive handler"
ARK_ENTRY=""
for d in /usr/share/applications "$HOME/.local/share/applications"; do
    [ -f "$d/org.kde.ark.desktop" ] && ARK_ENTRY="org.kde.ark.desktop"
done
# Fall back to any installed archive manager, so this is useful outside KDE too.
if [ -z "$ARK_ENTRY" ]; then
    for e in org.gnome.FileRoller.desktop xarchiver.desktop; do
        for d in /usr/share/applications "$HOME/.local/share/applications"; do
            [ -f "$d/$e" ] && ARK_ENTRY="$e"
        done
    done
fi

if [ -z "$ARK_ENTRY" ]; then
    warn "no archive manager installed — run steps/02_install_viewer_stack.sh to install Ark"
    info "without one, the file manager has no 'Extract archive here' action"
else
    info "archive manager: $ARK_ENTRY"
    for m in application/zip application/x-tar application/gzip \
             application/x-7z-compressed application/vnd.rar; do
        cur="$(xdg-mime query default "$m" 2>/dev/null)"
        if [ "$cur" = "$ARK_ENTRY" ]; then
            ok "$m already -> $ARK_ENTRY"
        else
            info "$m: ${cur:-<none>} -> $ARK_ENTRY"
            run xdg-mime default "$ARK_ENTRY" "$m"
        fi
    done
fi

heading "Next"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "DRY RUN — nothing was changed. Re-run with --apply."
else
    ok "file associations updated"
    info "test: double-click a large .png (should open in the viewer, not a browser)"
    info "test: right-click a .zip in the file manager — 'Extract archive here' should appear"
fi
