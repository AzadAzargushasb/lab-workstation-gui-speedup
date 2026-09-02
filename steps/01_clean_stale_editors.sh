#!/usr/bin/env bash
#
# 01_clean_stale_editors.sh — reclaim leaked OnlyOffice processes.
#
# WHY
#   OnlyOffice is built on CEF (Chromium Embedded Framework). Like a web browser, it runs a
#   pool of helper processes -- a main "DesktopEditors" process plus many "editors_helper"
#   children. Those helpers are supposed to exit when their document window closes. When
#   that goes wrong they keep running and keep consuming CPU indefinitely, because each one
#   is still driving a render loop for a document nobody is looking at.
#
#   On the machine this was written for: 21 processes, 14.8 GB of RAM, ~100% of a CPU core
#   burned continuously, and the oldest had been alive for 167 hours (nearly 7 days).
#
# WHAT COUNTS AS "STALE"
#   Age. A helper alive for days is not doing useful work -- nobody keeps a document open
#   and actively edits it for a week. The default threshold is 24 hours; --older-than
#   changes it, and --all ignores age entirely.
#
# ⚠ THIS CLOSES DOCUMENT WINDOWS
#   These processes may still own an on-screen window. Killing one closes that window, and
#   anything unsaved in it is lost. That is exactly why this script is dry-run by default:
#   run it bare first, read the list (it shows each process's age and, where it can, the
#   document it has open), save anything you care about, then re-run with --apply.
#
# HOW IT KILLS
#   SIGTERM first, which asks the process to shut down cleanly and lets it flush state.
#   Then it waits, re-checks, and only sends SIGKILL to whatever ignored the polite request.
#   SIGKILL cannot be caught or cleaned up after, so it is a last resort, never the opener.
#
# Usage:
#   ./01_clean_stale_editors.sh                     # dry run: list what would be killed
#   ./01_clean_stale_editors.sh --apply             # kill processes older than 24h
#   ./01_clean_stale_editors.sh --older-than 4      # dry run, 4-hour threshold
#   ./01_clean_stale_editors.sh --all --apply       # kill ALL OnlyOffice processes
set -uo pipefail

source "$(dirname "$(readlink -f "$0")")/_common.sh"

print_usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

THRESHOLD_HOURS=24
KILL_ALL=0

# Pull our own flags out first, then let the common parser handle --apply/--dry-run.
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --older-than) THRESHOLD_HOURS="${2:-24}"; shift ;;
        --all)        KILL_ALL=1 ;;
        *)            ARGS+=("$1") ;;
    esac
    shift
done
parse_common_flags "${ARGS[@]+"${ARGS[@]}"}"

heading "Step 1 — reclaim leaked OnlyOffice processes"
print_machine_line
announce_mode

# Count real processes by matching the COMMAND NAME (comm), never the full command line.
# Matching the command line with `pgrep -f` would also match any shell running a command
# that merely contains the word "editors_helper" -- including this script itself -- and
# report processes that do not exist.
count_editors() {
    ps -eo comm --no-headers 2>/dev/null | grep -cE "^(editors_helper|DesktopEditors)$"
}

if [ "$(count_editors)" -eq 0 ]; then
    ok "no OnlyOffice processes are running — nothing to do"
    exit 0
fi

THRESHOLD_SECS=$((THRESHOLD_HOURS * 3600))
[ "$KILL_ALL" -eq 1 ] && info "--all given: ignoring age, targeting every OnlyOffice process" \
                      || info "targeting processes older than ${THRESHOLD_HOURS}h"

# etimes = elapsed seconds, which is directly comparable; etime is a human string that is
# awkward to parse. rss is in KB.
TARGETS=()
printf '\n  %-8s %-10s %-7s %-10s %s\n' "PID" "AGE" "CPU%" "RAM(MB)" "OPEN DOCUMENT / COMMAND"
printf '  %s\n' "────────────────────────────────────────────────────────────────────────────"
while read -r pid etimes pcpu rss comm; do
    [ -z "${pid:-}" ] && continue
    if [ "$KILL_ALL" -eq 0 ] && [ "$etimes" -lt "$THRESHOLD_SECS" ]; then
        continue
    fi
    # Try to show which document this process has open, so the list is reviewable rather
    # than an opaque wall of PIDs.
    doc=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
          | grep -iE '\.(pptx|xlsx|docx|odp|ods|odt|pdf)$' | head -1)
    [ -z "$doc" ] && doc="($comm)" || doc="$(basename "$doc")"
    printf '  %-8s %-10s %-7s %-10s %s\n' \
           "$pid" "$((etimes/3600))h" "$pcpu" "$((rss/1024))" "$doc"
    TARGETS+=("$pid")
done < <(ps -eo pid,etimes,pcpu,rss,comm --no-headers 2>/dev/null \
         | awk '$5 ~ /editors_helper|DesktopEditors/ {print}')

if [ "${#TARGETS[@]}" -eq 0 ]; then
    printf '\n'
    ok "no processes exceed the ${THRESHOLD_HOURS}h threshold — nothing to reclaim"
    info "use --all to target every OnlyOffice process regardless of age"
    exit 0
fi

# Report what reclaiming these would actually recover.
RECLAIM_MB=$(ps -o rss= -p "$(IFS=,; echo "${TARGETS[*]}")" 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
RECLAIM_CPU=$(ps -o pcpu= -p "$(IFS=,; echo "${TARGETS[*]}")" 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}')
printf '\n'
info "${#TARGETS[@]} process(es) targeted — would free ~${RECLAIM_MB} MB and ~${RECLAIM_CPU}% CPU"

if [ "$DRY_RUN" -eq 1 ]; then
    printf '\n'
    warn "DRY RUN — nothing was killed."
    warn "Save any open OnlyOffice work first, then re-run with --apply."
    exit 0
fi

# ── Polite shutdown first ──────────────────────────────────────────────────────
heading "Sending SIGTERM (asks each process to close cleanly)"
for pid in "${TARGETS[@]}"; do
    kill -TERM "$pid" 2>/dev/null && info "TERM -> $pid" || info "$pid already gone"
done

# Give them a few seconds to flush and exit before escalating.
info "waiting 5s for clean shutdown..."
sleep 5

# ── Force-kill only what ignored SIGTERM ───────────────────────────────────────
SURVIVORS=()
for pid in "${TARGETS[@]}"; do
    kill -0 "$pid" 2>/dev/null && SURVIVORS+=("$pid")
done

if [ "${#SURVIVORS[@]}" -eq 0 ]; then
    ok "all targeted processes exited cleanly"
else
    heading "Sending SIGKILL to ${#SURVIVORS[@]} process(es) that ignored SIGTERM"
    for pid in "${SURVIVORS[@]}"; do
        kill -KILL "$pid" 2>/dev/null && info "KILL -> $pid"
    done
    sleep 1
fi

# ── Report the result ──────────────────────────────────────────────────────────
heading "Result"
REMAIN=$(count_editors)
if [ "$REMAIN" -eq 0 ]; then
    ok "no OnlyOffice processes remain — reclaimed ~${RECLAIM_MB} MB and ~${RECLAIM_CPU}% CPU"
else
    ok "reclaimed ~${RECLAIM_MB} MB and ~${RECLAIM_CPU}% CPU"
    info "$REMAIN OnlyOffice process(es) still running (newer than the threshold, left alone)"
fi

info "if leaked helpers reappear within days, that is an OnlyOffice bug worth reporting upstream"
