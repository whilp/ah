#!/bin/bash
# lib/work/fix-loop.sh: retry fix/push/check up to N times if verdict is needs-fixes
set -eo pipefail

cosmic="$1"
ah="$2"
max_retries="${3:-2}"

check_verdict() {
    local verdict
    verdict=$("$cosmic" lib/work/check-verdict.tl --actions o/work/check/actions.json 2>/dev/null) || return 1
    echo "$verdict"
}

for attempt in $(seq 1 "$max_retries"); do
    verdict=$(check_verdict) || break
    if [ "$verdict" != "needs-fixes" ]; then
        break
    fi

    echo "==> fix (attempt $attempt/$max_retries)"

    mkdir -p o/work/fix

    timeout 300 "$ah" -n \
        --sandbox \
        --skill fix \
        --max-tokens 100000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/fix/session.db \
        < o/work/issue.json \
        || true

    echo "==> push (fix)"
    git push -u origin HEAD

    echo "==> check (after fix)"
    mkdir -p o/work/check

    timeout 180 "$ah" -n \
        --sandbox \
        --skill check \
        --max-tokens 50000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/check/session.db \
        < /dev/null \
        || true
done
