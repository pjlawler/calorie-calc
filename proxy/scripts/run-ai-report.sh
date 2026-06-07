#!/bin/bash
# launchd wrapper for the daily AI activity snapshot. launchd runs with a minimal
# environment, so set PATH explicitly (node/npx/wrangler live in Homebrew) and pin the
# working directory to the repo. Output is appended to a rolling log for debugging.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REPO="/Users/patricklawler/github/calorie_calc"
LOG="$REPO/proxy/data/ai-report.log"
cd "$REPO" || exit 1
echo "===== run $(date -u +%Y-%m-%dT%H:%M:%SZ) =====" >> "$LOG"
node proxy/scripts/ai-activity.mjs >> "$LOG" 2>&1
echo "exit $?" >> "$LOG"
