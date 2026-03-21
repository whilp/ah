#!/bin/bash
# run-optimize.sh — drive the autowork loop for test speed optimization
# runs iterations until 10 consecutive non-improvements or 20 total iterations
set -uo pipefail

cd "$(dirname "$0")"

AH_BIN=${AH_BIN:-/persist/whilp/ah/o/bin/ah}
MAX_ITERS=20
MAX_FAILS=10
PROMPT="reduce make test wall clock time from clean build. focus on build/infrastructure optimizations. do not remove or skip tests unless they are genuinely not useful. the work document is work.md."

fails=0
for i in $(seq 1 $MAX_ITERS); do
  echo "=== iteration $i ==="
  if $AH_BIN --work ./work.sh "$PROMPT"; then
    fails=0
    echo "=== iteration $i: kept ==="
  else
    fails=$((fails + 1))
    echo "=== iteration $i: discarded/crashed (fails=$fails) ==="
  fi
  if [ "$fails" -ge "$MAX_FAILS" ]; then
    echo "=== $MAX_FAILS consecutive failures, stopping ==="
    break
  fi
done

echo "=== done after $i iterations ==="
