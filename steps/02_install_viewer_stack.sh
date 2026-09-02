#!/usr/bin/env bash
#
# 02_install_viewer_stack.sh — install faster viewers and the missing archive helper.
#
# WHY
#   Two separate gaps. First, the default image viewer decodes an image on the CPU and
#   rescales it on the CPU every time you pan or zoom; for very large scientific figures
#   that is the difference between fluid and unusable. Second, on KDE the file manager's
#   "Extract archive here" action is provided by a separate package (Ark) that is easy to
#   end up without -- and without it, unzipping from the file manager simply is not offered.
#
# WHAT GETS INSTALLED
#   From the official repositories (always):
#     ark                 the KDE archive tool. Restores "Extract archive here" in Dolphin.
#     imv                 lightweight OpenGL image viewer. Low-risk, in the official repos.
#     libreoffice-fresh   a native C++ office suite whose Skia renderer can draw on the GPU
#                         via Vulkan. Installed ALONGSIDE OnlyOffice, never replacing it --
#                         see the fidelity caveat below.
#
#   From the AUR (only with --with-aur, and only if yay/paru is present):
#     qimgv               OpenGL image viewer; the natural drop-in replacement for Gwenview.
#     vipsdisp            tiled, lazy, level-of-detail viewer built on libvips. It renders
#                         only the tiles you are actually looking at, at the zoom level you
#                         are looking at -- the same idea that makes huge maps feel instant.
#                         The best option for gigapixel images.
#     nomacs              (--extras) Qt viewer with good scientific metadata support.
#     wps-office          (--extras) proprietary suite with strong PowerPoint fidelity.
#     freeoffice          (--extras) SoftMaker's free suite; also native, also good fidelity.
#
# ⚠ LIBREOFFICE IS A TEST, NOT A VERDICT
#   LibreOffice gets you native code and GPU rendering, but its OOXML (.docx/.xlsx/.pptx)
#   fidelity is generally weaker than OnlyOffice's. If you edit decks and reopen them in
#   Microsoft PowerPoint, fidelity is not negotiable. Install both, open the SAME real file
#   in each, and keep whichever wins. This script never removes OnlyOffice.
#
# NON-ARCH MACHINES
#   Package installation is only implemented for Arch-family distros. Elsewhere the script
#   prints the equivalent package names and exits without touching anything.
#
# Usage:
#   ./02_install_viewer_stack.sh                        # dry run: list what would install
#   ./02_install_viewer_stack.sh --apply                # install the repo packages
#   ./02_install_viewer_stack.sh --with-aur --apply     # also install qimgv + vipsdisp
#   ./02_install_viewer_stack.sh --with-aur --extras --apply   # also the optional suites
#   ./02_install_viewer_stack.sh --no-office --apply    # skip LibreOffice
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

print_usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

WITH_AUR=0; WITH_EXTRAS=0; NO_OFFICE=0
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --with-aur) WITH_AUR=1 ;;
        --extras)   WITH_EXTRAS=1 ;;
        --no-office) NO_OFFICE=1 ;;
        *)          ARGS+=("$1") ;;
    esac
    shift
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

# Explain the most common way this install fails on a rolling-release distro. The error
# pacman prints ("invalid url for server", HTTP 404) names the symptom, not the cause.
diagnose_install_failure() {
    local newest_db age_days
    newest_db=$(ls -t /var/lib/pacman/sync/*.db 2>/dev/null | head -1)
    [ -z "$newest_db" ] && return 0
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$newest_db") ) / 86400 ))

    info ""
    info "LIKELY CAUSE: a stale local package database (${age_days} days old)."
    info "Arch mirrors carry only the CURRENT build of each package; superseded builds are"
    info "deleted. If your database still names a version that has since been rebuilt, that"
    info "filename now returns 404 from every mirror. The fix is to refresh the database"
    info "AND upgrade in one transaction:"
    info ""
    info "    sudo pacman -Syu"
    info ""
    warn "Do NOT run 'pacman -Sy <package>'. Syncing the database without upgrading leaves"
    warn "the system in a partial-upgrade state, where newly installed packages are built"
    warn "against libraries you do not have. That breaks things in confusing ways later."
}

heading "Step 2 — install faster viewers and the archive helper"
print_machine_line
announce_mode

# ── Guard: distro ──────────────────────────────────────────────────────────────
if ! is_arch; then
    skip_step "package installation is only implemented for Arch-family distros (found: $(detect_distro))"
    cat <<'EOT'

  Equivalent packages on other distros:
    Debian / Ubuntu : sudo apt install ark imv libreoffice nomacs
    Fedora          : sudo dnf install ark imv libreoffice nomacs
    qimgv and vipsdisp are usually not packaged; build from source or use flatpak.
EOT
    exit 0
fi

# ── Guard: root ────────────────────────────────────────────────────────────────
# A password prompt is fine here (a human is running this), so we check that sudo EXISTS
# rather than that it works without a password.
if ! sudo_available; then
    fail "no sudo available and not running as root — cannot install packages"
    info "ask an administrator to install the packages listed below"
fi

# ── Decide the repo package list ───────────────────────────────────────────────
REPO_PKGS=(ark imv)
[ "$NO_OFFICE" -eq 0 ] && REPO_PKGS+=(libreoffice-fresh)

TO_INSTALL=(); ALREADY=()
for p in "${REPO_PKGS[@]}"; do
    if pkg_installed "$p"; then ALREADY+=("$p"); else TO_INSTALL+=("$p"); fi
done

heading "Official repository packages"
for p in "${ALREADY[@]+"${ALREADY[@]}"}";   do ok   "$p is already installed"; done
for p in "${TO_INSTALL[@]+"${TO_INSTALL[@]}"}"; do info "$p will be installed"; done

# Tracks whether anything actually failed, so the summary cannot claim success after a
# failed transaction. pacman is ATOMIC: if one package in the set fails to download, NOTHING
# in that transaction is installed -- not even the packages that downloaded fine.
INSTALL_FAILED=0

if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    # --needed makes this idempotent: already-current packages are left alone rather than
    # reinstalled, so re-running the script is cheap and safe.
    run $SUDO pacman -S --needed "${TO_INSTALL[@]}" || INSTALL_FAILED=1
else
    ok "all repository packages already present"
fi

# Ground truth beats exit codes: ask the package database what is actually installed now,
# rather than trusting that a zero exit meant success.
if [ "$DRY_RUN" -eq 0 ] && [ "${#TO_INSTALL[@]}" -gt 0 ]; then
    STILL_MISSING=()
    for p in "${TO_INSTALL[@]}"; do
        pkg_installed "$p" || STILL_MISSING+=("$p")
    done
    if [ "${#STILL_MISSING[@]}" -gt 0 ]; then
        INSTALL_FAILED=1
        fail "still not installed after the attempt: ${STILL_MISSING[*]}"
        diagnose_install_failure
    else
        ok "all repository packages installed"
    fi
fi

# ── AUR packages ───────────────────────────────────────────────────────────────
heading "AUR packages"
if [ "$WITH_AUR" -eq 0 ]; then
    skip_step "AUR packages not requested (pass --with-aur to include qimgv and vipsdisp)"
    info "these are the two that most improve large-image handling"
else
    HELPER="$(aur_helper)"
    if [ -z "$HELPER" ]; then
        warn "no AUR helper (yay/paru) found — skipping AUR packages"
        info "install one, or build qimgv/vipsdisp manually from the AUR"
    else
        info "using AUR helper: $HELPER"
        AUR_PKGS=(qimgv vipsdisp)
        [ "$WITH_EXTRAS" -eq 1 ] && AUR_PKGS+=(nomacs wps-office freeoffice)

        AUR_TODO=()
        for p in "${AUR_PKGS[@]}"; do
            if pkg_installed "$p"; then ok "$p is already installed"; else AUR_TODO+=("$p"); fi
        done
        if [ "${#AUR_TODO[@]}" -gt 0 ]; then
            for p in "${AUR_TODO[@]}"; do info "$p will be built from the AUR"; done
            warn "AUR packages are built from source — this can take several minutes each"
            # Deliberately NOT passing --noconfirm: AUR builds occasionally ask real
            # questions (dependency choices, conflicting providers) that should not be
            # auto-answered on someone else's workstation.
            run "$HELPER" -S --needed "${AUR_TODO[@]}" || INSTALL_FAILED=1
            if [ "$DRY_RUN" -eq 0 ]; then
                for p in "${AUR_TODO[@]}"; do
                    pkg_installed "$p" || { INSTALL_FAILED=1; fail "$p was not installed"; }
                done
            fi
        else
            ok "all requested AUR packages already present"
        fi
    fi
fi

# ── What to do next ────────────────────────────────────────────────────────────
heading "Next"
if [ "$DRY_RUN" -eq 1 ]; then
    warn "DRY RUN — nothing was installed. Re-run with --apply."
elif [ "$INSTALL_FAILED" -eq 1 ]; then
    fail "INSTALLATION DID NOT COMPLETE — see the errors above"
    info "the later steps can only configure software that is actually installed"
    # Non-zero exit so gui_perf_fix.sh reports this step as failed rather than
    # continuing silently as though it had worked.
    exit 1
else
    ok "installation step complete"
    info "run steps/03_enable_gpu_accel.sh next — installing LibreOffice is not enough,"
    info "its GPU renderer still has to be switched on."
fi
