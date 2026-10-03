#!/bin/bash
# Surface compiler failures through check-run annotations, including when the
# environment cannot follow GitHub's external log-storage redirect.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/build-results
log="dist/build-results/build.log"
"$@" 2>&1 | tee "$log"
result=${PIPESTATUS[0]}
if [[ "$result" -ne 0 ]]; then
  matches="$(awk '/error:|Error:|command not found|fatal error|failed|Failed|FAIL/{ if (!seen[$0]++) { print; found=1; if (++count >= 40) exit } } END { if (!found) print "Command failed; inspect the last log lines." }' "$log")"
  if [[ "$matches" == 'Command failed; inspect the last log lines.' ]]; then
    matches="$(tail -n 30 "$log")"
  fi
  while IFS= read -r line; do
    line=${line//'%'/'%25'}
    line=${line//$'\r'/'%0D'}
    line=${line//$'\n'/'%0A'}
    echo "::error title=Hoover validation::$line"
  done <<< "$matches"
fi
exit "$result"
