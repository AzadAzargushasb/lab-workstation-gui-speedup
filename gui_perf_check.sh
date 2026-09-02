#!/usr/bin/env bash
#
# gui_perf_check.sh — diagnose why desktop apps feel slow. CHANGES NOTHING.
#
# WHAT THIS IS
#   A read-only report. It inspects the graphics stack, the running GUI processes, and a
#   handful of desktop settings, then prints PASS / WARN / FAIL for each with an
#   explanation. It never installs, edits, kills, or configures anything, so it is safe to
#   run on any machine and safe to hand to anyone.
#
# WHY IT EXISTS
#   "The app feels slow" is not actionable. This turns that into specific, checkable facts:
#   is the app rendering on the GPU or on the CPU? Are there leaked processes eating cores?
#   Is a huge image being handed to a web browser because of a stale file association?
#
# THE CENTRAL CHECK
#   A GPU-accelerated program shows up in `nvidia-smi` as a running process. One that has
#   silently fallen back to CPU rendering does not. That single distinction explains most
#   of the slowness this repo addresses, so it is checked explicitly per application.
#
# HOW TO READ THE OUTPUT
#   PASS  nothing to do
#   WARN  works, but is leaving performance on the table -- gui_perf_fix.sh can address it
#   FAIL  actively causing the slowness you are seeing
#   SKIP  does not apply to this machine (wrong GPU vendor, wrong desktop, app not installed)
#
# Usage:
#   ./gui_perf_check.sh              # print the report
#   ./gui_perf_check.sh --log        # also write it to logs/
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/steps/_common.sh"

print_usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

WANT_LOG=0
for a in "$@"; do
    case "$a" in
        --log)     WANT_LOG=1 ;;
        -h|--help) print_usage; exit 0 ;;
    esac
done
[ "$WANT_LOG" -eq 1 ] && start_log "gui_perf_check"

# Tally so the summary can say how much is actually wrong.
N_PASS=0; N_WARN=0; N_FAIL=0
p() { ok   "$*"; N_PASS=$((N_PASS+1)); }
w() { warn "$*"; N_WARN=$((N_WARN+1)); }
f() { fail "$*"; N_FAIL=$((N_FAIL+1)); }

printf '%s\n' "════════════════════════════════════════════════════════════════════"
printf '%s\n' " GUI performance check — read-only, changes nothing"
printf '%s\n' "════════════════════════════════════════════════════════════════════"
print_machine_line

DISTRO="$(detect_distro)"
GPU="$(detect_gpu_vendor)"
DE="$(detect_de)"

# ─────────────────────────────────────────────────────────────────────────────
heading "1. Graphics hardware and driver"
# ─────────────────────────────────────────────────────────────────────────────
# A GPU that is present but running a driver with no 3D acceleration is worse than useless
# here: applications think acceleration exists, try it, fail, and fall back to CPU rendering
# without telling you.
case "$GPU" in
    nvidia)
        p "NVIDIA GPU with the proprietary driver bound"
        if have_cmd nvidia-smi; then
            nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total \
                       --format=csv,noheader 2>/dev/null | sed 's/^/         /'
        fi
        # libGLX_nvidia is the library an app must load to get hardware OpenGL. If it is
        # missing, every OpenGL app silently renders on the CPU.
        if ls /usr/lib/libGLX_nvidia.so.* >/dev/null 2>&1 || ls /usr/lib64/libGLX_nvidia.so.* >/dev/null 2>&1; then
            p "hardware OpenGL library present (libGLX_nvidia.so)"
        else
            f "libGLX_nvidia.so missing — OpenGL apps cannot use the GPU"
        fi
        ;;
    amd|intel) p "$GPU GPU with an open-source driver (hardware GL via Mesa)" ;;
    nouveau)   w "NVIDIA card running nouveau — 3D performance is very limited; the proprietary driver is strongly preferred" ;;
    none)      w "no discrete/integrated GPU detected — everything will render on the CPU and this repo cannot help much" ;;
esac

# Vulkan matters specifically because LibreOffice's Skia renderer uses it for GPU drawing.
if have_cmd vulkaninfo; then
    VK=$(vulkaninfo --summary 2>/dev/null | grep -m1 'deviceName' | sed 's/.*= *//')
    if [ -n "$VK" ]; then p "Vulkan available: $VK"
    else w "vulkaninfo present but reported no device (often just needs a display; harmless over SSH)"; fi
elif [ -d /usr/share/vulkan/icd.d ] && [ -n "$(ls -A /usr/share/vulkan/icd.d 2>/dev/null)" ]; then
    p "Vulkan driver files installed ($(ls /usr/share/vulkan/icd.d | tr '\n' ' '))"
else
    w "no Vulkan driver found — LibreOffice's Skia GPU renderer will fall back to software"
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "2. Are GUI applications actually using the GPU?"
# ─────────────────────────────────────────────────────────────────────────────
# This is the heart of the diagnosis. For each app of interest: is it running, and if so,
# does the GPU know about it?
if [ "$GPU" = "nvidia" ] && have_cmd nvidia-smi; then
    GPU_PROCS="$(nvidia-smi 2>/dev/null | sed -n '/Processes:/,$p')"

    check_app_on_gpu() {
        local pattern="$1" label="$2"
        if ! pgrep -f "$pattern" >/dev/null 2>&1; then
            skip "$label is not running (start it, then re-run this check)"
            return
        fi
        if printf '%s' "$GPU_PROCS" | grep -qi "$pattern"; then
            p "$label is on the GPU"
        else
            f "$label is RUNNING BUT NOT ON THE GPU — it is rendering in software on the CPU"
        fi
    }

    check_app_on_gpu 'DesktopEditors|editors_helper' 'OnlyOffice'
    check_app_on_gpu 'soffice'                       'LibreOffice'
    check_app_on_gpu 'gwenview'                      'Gwenview'
    check_app_on_gpu 'qimgv'                         'qimgv'
    check_app_on_gpu 'vipsdisp'                      'vipsdisp'
else
    skip "per-application GPU check needs an NVIDIA GPU with nvidia-smi"
fi

# SwiftShader is Chromium's pure-software rasterizer: it draws every pixel with the CPU.
# Any Chromium-based app that loads it has given up on the GPU entirely. Finding this
# mapped into a running process is direct proof of software rendering.
heading "3. Software-rasterizer (SwiftShader) detection"
SW_FOUND=0
for pid in $(pgrep -f 'DesktopEditors|editors_helper|soffice' 2>/dev/null); do
    if grep -q 'swiftshader' "/proc/$pid/maps" 2>/dev/null; then
        SW_FOUND=$((SW_FOUND+1))
    fi
done
if [ "$SW_FOUND" -gt 0 ]; then
    f "$SW_FOUND process(es) have SwiftShader loaded — confirmed CPU-only rendering"
    info "SwiftShader draws every pixel on the CPU. This is the main cause of the slowness."
else
    if pgrep -f 'DesktopEditors|editors_helper|soffice' >/dev/null 2>&1; then
        p "no SwiftShader in the running office processes"
    else
        skip "no office application running to inspect"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "4. Leaked / stale editor processes"
# ─────────────────────────────────────────────────────────────────────────────
# OnlyOffice is built on CEF (Chromium Embedded Framework), which runs a pool of helper
# processes. They are supposed to exit when their window closes. When they do not, they
# keep spinning CPU forever. Age is the giveaway: a helper alive for days is not doing work.
mapfile -t STALE < <(ps -eo pid,etimes,pcpu,rss,comm --no-headers 2>/dev/null \
                     | awk '$5 ~ /editors_helper|DesktopEditors/ {print}')
if [ "${#STALE[@]}" -eq 0 ]; then
    p "no OnlyOffice processes running"
else
    TOT_RSS=$(printf '%s\n' "${STALE[@]}" | awk '{s+=$4} END {printf "%.1f", s/1024}')
    TOT_CPU=$(printf '%s\n' "${STALE[@]}" | awk '{s+=$3} END {printf "%.1f", s}')
    OLDEST=$(printf '%s\n' "${STALE[@]}" | awk '{if($2>m) m=$2} END {printf "%d", m/3600}')
    OLD_CT=$(printf '%s\n' "${STALE[@]}" | awk '$2 > 86400' | wc -l)

    info "${#STALE[@]} process(es), ${TOT_RSS} MB resident, ${TOT_CPU}% CPU, oldest ${OLDEST}h"
    if [ "$OLD_CT" -gt 0 ]; then
        f "$OLD_CT process(es) older than 24h — these are leaked and burning CPU for nothing"
        info "steps/01_clean_stale_editors.sh reclaims them"
    elif [ "${TOT_CPU%.*}" -gt 20 ]; then
        w "OnlyOffice is using ${TOT_CPU}% CPU — high for an idle editor (software rendering)"
    else
        p "OnlyOffice process count and age look normal"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "5. File associations"
# ─────────────────────────────────────────────────────────────────────────────
# A MIME default decides which program opens a file type on double-click. A wrong one here
# is quietly expensive: handing a several-hundred-megapixel PNG to a web browser is far
# slower than any real image viewer.
check_mime() {
    local mime="$1" desc="$2"
    local cur; cur="$(xdg-mime query default "$mime" 2>/dev/null)"
    if [ -z "$cur" ]; then
        f "$desc ($mime) has NO default application registered"
    elif printf '%s' "$cur" | grep -qi 'chromium\|firefox\|google-chrome'; then
        f "$desc ($mime) opens in a web browser: $cur"
        info "a browser is a poor image viewer for very large files"
    else
        p "$desc ($mime) -> $cur"
    fi
}
if have_cmd xdg-mime; then
    check_mime image/png       "PNG images"
    check_mime image/jpeg      "JPEG images"
    check_mime image/tiff      "TIFF images"
    check_mime application/zip "ZIP archives"
else
    skip "xdg-mime not installed; cannot inspect file associations"
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "6. Archive handling"
# ─────────────────────────────────────────────────────────────────────────────
# On KDE, the "Extract archive here" right-click action in Dolphin comes from Ark. Without
# Ark installed there is no extract action at all, which reads as "the file manager cannot
# unzip" when really the helper is just absent.
if [ "$DE" = "kde" ]; then
    if pkg_installed ark || have_cmd ark; then
        p "Ark installed — Dolphin has 'Extract archive here'"
    else
        f "Ark NOT installed — Dolphin has no extract action (this is the whole unzip problem)"
    fi
else
    skip "archive-helper check is KDE-specific (detected: $DE)"
fi
for t in unzip 7z bsdtar; do
    have_cmd "$t" && info "command-line extractor available: $t"
done

# ─────────────────────────────────────────────────────────────────────────────
heading "7. File-manager thumbnail cap (KDE)"
# ─────────────────────────────────────────────────────────────────────────────
# To draw a thumbnail the file manager must fully decode the image. With no size cap it
# will decode a 100+ MB image just to paint a small icon, freezing the folder view.
if [ "$DE" = "kde" ]; then
    DRC="$HOME/.config/dolphinrc"
    CAP=$(sed -n '/^\[PreviewSettings\]/,/^\[/p' "$DRC" 2>/dev/null | grep -m1 '^MaximumSize=' | cut -d= -f2)
    if [ -n "$CAP" ]; then
        p "Dolphin preview cap set: $((CAP/1024/1024)) MB"
    else
        w "no Dolphin preview size cap set — it will try to thumbnail very large images"
        info "steps/05_tune_dolphin_previews.sh sets a sane cap"
    fi
else
    skip "thumbnail-cap check is KDE-specific (detected: $DE)"
fi

# ─────────────────────────────────────────────────────────────────────────────
heading "8. Faster viewers installed?"
# ─────────────────────────────────────────────────────────────────────────────
FOUND=""
for v in vipsdisp qimgv imv nomacs; do have_cmd "$v" && FOUND="$FOUND $v"; done
if [ -n "$FOUND" ]; then
    p "GPU-capable image viewer(s) present:$FOUND"
else
    w "no GPU-accelerated image viewer installed (only Gwenview / a browser)"
    info "steps/02_install_viewer_stack.sh installs them"
fi
have_cmd soffice && p "LibreOffice installed (native renderer, can use Skia+Vulkan)" \
                 || info "LibreOffice not installed — worth testing against OnlyOffice"

# ─────────────────────────────────────────────────────────────────────────────
heading "9. Memory safety"
# ─────────────────────────────────────────────────────────────────────────────
# Relevant because leaked editor processes hold gigabytes. With swap configured, running
# low means slowdown; with no swap at all, the kernel's OOM killer terminates a process
# outright -- possibly the one holding your unsaved work.
SWAP_KB=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
MEM_GB=$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)
if [ "${SWAP_KB:-0}" -eq 0 ]; then
    w "no swap configured (RAM: ${MEM_GB} GB) — memory exhaustion kills processes rather than slowing down"
else
    p "swap configured: $((SWAP_KB/1048576)) GB (RAM: ${MEM_GB} GB)"
fi

# ─────────────────────────────────────────────────────────────────────────────
printf '\n%s\n' "════════════════════════════════════════════════════════════════════"
printf ' Summary:  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' \
       "$C_GRN" "$N_PASS" "$C_OFF" "$C_YEL" "$N_WARN" "$C_OFF" "$C_RED" "$N_FAIL" "$C_OFF"
printf '%s\n' "════════════════════════════════════════════════════════════════════"
if [ "$N_FAIL" -gt 0 ]; then
    printf '\nRun %s./gui_perf_fix.sh%s to preview fixes (it changes nothing without --apply).\n' "$C_BLD" "$C_OFF"
fi
# Exit 0 even when findings exist: this is a report, not a test. A non-zero exit would make
# it awkward to run from other scripts or a CI-style loop across the fleet.
exit 0
