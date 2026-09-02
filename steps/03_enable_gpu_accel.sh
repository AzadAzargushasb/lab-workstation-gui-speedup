#!/usr/bin/env bash
#
# 03_enable_gpu_accel.sh — make OnlyOffice and LibreOffice render on the GPU. THE CORE FIX.
#
# THE PROBLEM, IN ONE PARAGRAPH
#   Drawing a document means turning shapes, text and images into pixels. That job is called
#   rasterization, and a GPU exists to do it thousands of times faster than a CPU. OnlyOffice
#   is built on CEF (the engine inside Chrome), and CEF keeps a "blocklist" of graphics
#   drivers it does not trust. The NVIDIA proprietary driver on Linux is on that list. When
#   CEF refuses the GPU it does not warn you -- it silently switches to SwiftShader, a
#   software rasterizer that draws every single pixel with the CPU, and carries on. On a
#   many-core-but-low-clock workstation CPU that is close to the worst case, because
#   rasterization runs on ONE core and those cores are individually slow.
#
#   This is why the same presentation is smooth in PowerPoint on Windows (which renders
#   through DirectX on the GPU) and sluggish here. It is not the file, and not the network.
#
# WHAT THIS SCRIPT DOES
#   OnlyOffice — writes a user-level copy of the application's .desktop launcher with GPU
#     flags added, so launching it from the menu or a file manager uses the GPU. The flags
#     were verified to exist in the bundled CEF build:
#       --ignore-gpu-blocklist          use the GPU even though the driver is blocklisted
#       --enable-gpu-rasterization      rasterize on the GPU rather than the CPU
#       --enable-zero-copy              hand textures to the GPU without an extra CPU copy
#       --disable-software-rasterizer   refuse the silent SwiftShader fallback (see below)
#
#     A USER-LEVEL override (in ~/.local/share/applications) is used rather than editing the
#     system file, so a package update cannot clobber it and no root is needed.
#
#     --disable-software-rasterizer is deliberate: without it a failed GPU setup falls back
#     to software silently and you learn nothing. With it, failure is loud. If the app then
#     refuses to start, re-run with --safe-flags, which drops that one flag.
#
#   LibreOffice — turns on Skia, its modern renderer, and makes sure it uses the GPU
#     (via Vulkan) rather than Skia's own CPU mode. Two settings in the user profile:
#       UseSkia         = true    use the Skia renderer
#       ForceSkiaRaster = false   let Skia use the GPU instead of forcing CPU drawing
#
# ⚠ THE AUTHORITATIVE ROUTE FOR LIBREOFFICE IS THE GUI
#   LibreOffice owns its profile file and rewrites it on exit, so a hand-edit can be undone
#   by the application itself. The reliable way is:
#       Tools > Options > LibreOffice > View > Graphics Output
#         [x] Use Skia for all rendering
#         [ ] Force Skia software rendering     <- must stay UNTICKED
#   This script edits the profile as a convenience and always backs it up first, but if the
#   verification below does not show the GPU in use, use the menu and trust it over this.
#
# HOW TO KNOW IT WORKED
#   Not "it launched". The test is whether the graphics driver reports the application as a
#   running GPU client:  nvidia-smi | grep -i editor
#   Before this fix that returns nothing. After, it must list the process. Run
#   ../gui_perf_check.sh to have that checked for you.
#
# Usage:
#   ./03_enable_gpu_accel.sh                  # dry run: show the exact files and lines
#   ./03_enable_gpu_accel.sh --apply          # write the launcher override and profile
#   ./03_enable_gpu_accel.sh --safe-flags --apply   # omit --disable-software-rasterizer
#   ./03_enable_gpu_accel.sh --onlyoffice --apply   # only OnlyOffice
#   ./03_enable_gpu_accel.sh --libreoffice --apply  # only LibreOffice
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

print_usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; }

SAFE_FLAGS=0; DO_OO=1; DO_LO=1
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --safe-flags)  SAFE_FLAGS=1 ;;
        --onlyoffice)  DO_OO=1; DO_LO=0 ;;
        --libreoffice) DO_LO=1; DO_OO=0 ;;
        *)             ARGS+=("$1") ;;
    esac
    shift
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

heading "Step 3 — enable GPU rendering (the core fix)"
print_machine_line
announce_mode

GPU="$(detect_gpu_vendor)"
if [ "$GPU" = "none" ]; then
    skip_step "no GPU detected — there is nothing to accelerate onto"
    exit 0
fi
[ "$GPU" = "nouveau" ] && warn "nouveau driver: GPU rendering may be enabled but will still be slow; the proprietary NVIDIA driver is strongly preferred"

# ══════════════════════════════════════════════════════════════════════════════
# OnlyOffice
# ══════════════════════════════════════════════════════════════════════════════
if [ "$DO_OO" -eq 1 ]; then
heading "OnlyOffice — GPU flags on the launcher"

SYS_DESKTOP=""
for cand in /usr/share/applications/onlyoffice-desktopeditors.desktop \
            /usr/share/applications/onlyoffice-desktopeditors.desktop \
            /var/lib/flatpak/exports/share/applications/org.onlyoffice.desktopeditors.desktop; do
    [ -f "$cand" ] && { SYS_DESKTOP="$cand"; break; }
done
# Fall back to a search, since packaging names vary between distros.
[ -z "$SYS_DESKTOP" ] && SYS_DESKTOP=$(grep -rls 'onlyoffice\|desktopeditors' /usr/share/applications/ 2>/dev/null | head -1)

if [ -z "$SYS_DESKTOP" ]; then
    skip_step "OnlyOffice is not installed — nothing to configure"
else
    info "system launcher: $SYS_DESKTOP"

    GPU_FLAGS="--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy"
    if [ "$SAFE_FLAGS" -eq 1 ]; then
        info "--safe-flags: omitting --disable-software-rasterizer"
    else
        GPU_FLAGS="$GPU_FLAGS --disable-software-rasterizer"
    fi
    info "flags: $GPU_FLAGS"

    USER_DIR="$HOME/.local/share/applications"
    USER_DESKTOP="$USER_DIR/$(basename "$SYS_DESKTOP")"

    # Show exactly which lines change. There are typically FIVE Exec= lines -- the main
    # entry plus one per "New document/spreadsheet/presentation/form" action -- and every
    # one must be patched or those menu actions still launch without acceleration.
    N_EXEC=$(grep -c '^Exec=' "$SYS_DESKTOP" 2>/dev/null || echo 0)
    info "$N_EXEC Exec= line(s) will be rewritten"
    printf '\n  %sbefore:%s\n' "$C_DIM" "$C_OFF"
    grep '^Exec=' "$SYS_DESKTOP" | sed 's/^/    /'
    printf '\n  %safter:%s\n' "$C_DIM" "$C_OFF"
    grep '^Exec=' "$SYS_DESKTOP" \
        | sed -E "s|^(Exec=[^ ]+)|\1 $GPU_FLAGS|" | sed 's/^/    /'
    printf '\n'

    run mkdir -p "$USER_DIR"
    [ -f "$USER_DESKTOP" ] && backup_file "$USER_DESKTOP"

    # Insert the flags immediately after the executable path on each Exec= line, leaving
    # any trailing arguments (%F, --new:word) in place after them.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s  would: write %s with GPU flags%s\n' "$C_DIM" "$USER_DESKTOP" "$C_OFF"
    else
        sed -E "s|^(Exec=[^ ]+)|\1 $GPU_FLAGS|" "$SYS_DESKTOP" > "$USER_DESKTOP" \
            && ok "wrote $USER_DESKTOP"
        # Refresh the desktop database so the menu picks up the override immediately.
        have_cmd update-desktop-database && update-desktop-database "$USER_DIR" 2>/dev/null
    fi

    info "already-running OnlyOffice windows keep the OLD behaviour — fully quit and reopen"
fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# LibreOffice
# ══════════════════════════════════════════════════════════════════════════════
if [ "$DO_LO" -eq 1 ]; then
heading "LibreOffice — Skia renderer on the GPU"

if ! have_cmd soffice && ! have_cmd libreoffice; then
    skip_step "LibreOffice is not installed (steps/02_install_viewer_stack.sh installs it)"
else
    LO_BIN=$(command -v soffice || command -v libreoffice)
    info "binary: $LO_BIN"

    if pgrep -x soffice.bin >/dev/null 2>&1; then
        fail "LibreOffice is running — it rewrites its profile on exit and would undo this"
        info "close LibreOffice completely, then re-run this step"
    else
        LO_PROFILE="$HOME/.config/libreoffice/4/user/registrymodifications.xcu"

        # The profile only exists after LibreOffice has been run at least once.
        if [ ! -f "$LO_PROFILE" ]; then
            warn "no LibreOffice profile yet — it is created on first launch"
            if [ "$DRY_RUN" -eq 1 ]; then
                printf '%s  would: launch LibreOffice once headless to create the profile%s\n' "$C_DIM" "$C_OFF"
            else
                info "launching LibreOffice once (headless) to create it..."
                timeout 90 "$LO_BIN" --headless --terminate_after_init >/dev/null 2>&1
                sleep 2
            fi
        fi

        if [ ! -f "$LO_PROFILE" ] && [ "$DRY_RUN" -eq 0 ]; then
            fail "profile still not created — set this via the GUI instead:"
            info "Tools > Options > LibreOffice > View > Graphics Output > Use Skia for all rendering"
        else
            backup_file "$LO_PROFILE"

            # Two settings, both under the VCL branch of the configuration tree.
            #   UseSkia=true          -> use the Skia renderer at all
            #   ForceSkiaRaster=false -> let Skia use the GPU (true would force CPU drawing)
            # oor:op="fuse" means "set this value, replacing any existing one".
            ITEMS='<item oor:path="/org.openoffice.Office.Common/VCL"><prop oor:name="UseSkia" oor:op="fuse"><value>true</value></prop></item><item oor:path="/org.openoffice.Office.Common/VCL"><prop oor:name="ForceSkiaRaster" oor:op="fuse"><value>false</value></prop></item>'

            info "settings: UseSkia=true, ForceSkiaRaster=false"
            if [ "$DRY_RUN" -eq 1 ]; then
                printf '%s  would: insert the Skia settings into %s%s\n' "$C_DIM" "$LO_PROFILE" "$C_OFF"
            else
                # Remove any existing copies of these two properties first, so re-running
                # cannot accumulate duplicate entries, then insert fresh ones before the
                # closing tag.
                python3 - "$LO_PROFILE" "$ITEMS" <<'PYEOF'
import re, sys
path, items = sys.argv[1], sys.argv[2]
xml = open(path, encoding='utf-8').read()
for name in ('UseSkia', 'ForceSkiaRaster'):
    xml = re.sub(
        r'<item oor:path="/org\.openoffice\.Office\.Common/VCL"><prop oor:name="%s".*?</item>' % name,
        '', xml, flags=re.S)
if '</oor:items>' in xml:
    xml = xml.replace('</oor:items>', items + '</oor:items>')
    open(path, 'w', encoding='utf-8').write(xml)
    print("  patched")
else:
    sys.exit("  unexpected profile format; use the GUI route instead")
PYEOF
                [ $? -eq 0 ] && ok "Skia enabled in the LibreOffice profile" \
                             || fail "could not patch the profile — use the GUI route"
            fi
            info "verify in the app: Help > About shows the active rendering backend"
        fi
    fi
fi
fi

# ══════════════════════════════════════════════════════════════════════════════
heading "Verifying"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "DRY RUN — nothing was changed. Re-run with --apply."
else
    ok "configuration written"
    cat <<'EOT'

  To confirm it actually worked:
    1. Fully quit OnlyOffice and LibreOffice (close every window).
    2. Reopen one of them from the applications menu -- NOT from a terminal, so the
       patched launcher is used -- and load a real document.
    3. Run:   nvidia-smi | grep -iE 'editor|soffice'
       The application must now be listed. If nothing appears, it is still rendering
       on the CPU: re-run this script with --safe-flags, and set LibreOffice's Skia
       option from the GUI (Tools > Options > LibreOffice > View > Graphics Output).
    4. Or simply run:   ../gui_perf_check.sh
EOT
fi
