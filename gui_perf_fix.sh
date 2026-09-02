#!/usr/bin/env bash
#
# gui_perf_fix.sh — run every fix in order. Dry-run by default.
#
# WHAT THIS IS
#   A driver. It runs the numbered scripts in steps/ in the right order and passes your
#   flags through to each. Every step is also runnable on its own if you would rather do
#   them one at a time -- this is purely a convenience, not extra logic.
#
# THE ORDER MATTERS
#   1. clean stale editors     free the CPU and RAM being wasted before measuring anything
#   2. install viewer stack    the later steps can only configure what exists
#   3. enable GPU acceleration THE CORE FIX -- moves rendering off the CPU
#   4. fix file associations   needs step 2 to have installed the viewer it points at
#   5. cap thumbnail previews  independent, but cheap and belongs with the rest
#
# SAFETY
#   Nothing changes unless you pass --apply. Run it bare first and read what it intends to
#   do; every step prints its planned actions in full.
#
#   Step 1 can close open document windows (it kills leaked editor processes). In a full
#   run it is therefore SKIPPED unless you explicitly pass --clean, so that a routine
#   "fix my graphics" run can never cost you unsaved work by surprise.
#
# Usage:
#   ./gui_perf_fix.sh                        # dry run of everything (recommended first)
#   ./gui_perf_fix.sh --apply                # apply steps 2-5
#   ./gui_perf_fix.sh --clean --apply        # also reclaim leaked editor processes
#   ./gui_perf_fix.sh --with-aur --apply     # include the AUR viewers (qimgv, vipsdisp)
#   ./gui_perf_fix.sh --only 3 --apply       # run just one step
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/steps/_common.sh"

print_usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }

STEPS_DIR="$(dirname "$(readlink -f "$0")")/steps"
DO_CLEAN=0; ONLY=""; PASSTHRU=()

while [ $# -gt 0 ]; do
    case "$1" in
        --clean)     DO_CLEAN=1 ;;
        --only)      ONLY="${2:-}"; shift ;;
        -h|--help)   print_usage; exit 0 ;;
        --apply)     DRY_RUN=0; PASSTHRU+=("--apply") ;;
        *)           PASSTHRU+=("$1") ;;
    esac
    shift
done

start_log "gui_perf_fix"

printf '%s\n' "════════════════════════════════════════════════════════════════════"
printf '%s\n' " GUI performance fix"
printf '%s\n' "════════════════════════════════════════════════════════════════════"
print_machine_line
announce_mode

# Steps 2-5 by default. Step 1 is opt-in because it can close windows.
declare -a PLAN
[ "$DO_CLEAN" -eq 1 ] && PLAN+=("01_clean_stale_editors.sh")
PLAN+=("02_install_viewer_stack.sh" "03_enable_gpu_accel.sh" \
       "04_fix_file_associations.sh" "05_tune_dolphin_previews.sh")

if [ -n "$ONLY" ]; then
    match=$(printf '%s\n' "${PLAN[@]}" "01_clean_stale_editors.sh" | grep -m1 "^0*${ONLY}_" || true)
    if [ -z "$match" ]; then
        fail "no step matching '--only $ONLY' (valid: 1-5)"
        exit 1
    fi
    PLAN=("$match")
fi

if [ "$DO_CLEAN" -eq 0 ] && [ -z "$ONLY" ]; then
    info "step 1 (reclaim leaked editor processes) is skipped — pass --clean to include it"
fi

FAILED=()
for s in "${PLAN[@]}"; do
    printf '\n%s────────────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_OFF"
    if [ ! -x "$STEPS_DIR/$s" ]; then
        fail "missing or non-executable: steps/$s"
        FAILED+=("$s")
        continue
    fi
    # Each step re-parses the flags itself, so pass them straight through. A step that
    # fails does not abort the rest: they are independent, and a machine missing one
    # application should still get the other fixes.
    "$STEPS_DIR/$s" "${PASSTHRU[@]+"${PASSTHRU[@]}"}" || FAILED+=("$s")
done

printf '\n%s\n' "════════════════════════════════════════════════════════════════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
    ok "all steps completed"
else
    warn "${#FAILED[@]} step(s) reported a problem: ${FAILED[*]}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\nThis was a %sDRY RUN%s. Re-run with %s--apply%s to make these changes.\n' \
           "$C_BLD" "$C_OFF" "$C_BLD" "$C_OFF"
else
    cat <<'EOT'

Now verify:
  1. Fully quit and reopen OnlyOffice / LibreOffice so the new launcher is used.
  2. ./gui_perf_check.sh
     The applications should now be listed as GPU processes rather than FAIL.
EOT
fi
printf '%s\n' "════════════════════════════════════════════════════════════════════"
