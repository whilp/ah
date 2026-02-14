#!/bin/bash
# lib/work/fix-loop.sh: retry fix/push/check up to N times if verdict is needs-fixes
set -eo pipefail

cosmic="$1"
ah="$2"
model="${3:-}"
max_retries="${4:-2}"

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
    branch=$("$cosmic" lib/work/extract-branch.tl --plan o/work/plan/plan.md --issue o/work/issue.json)

    # run fix agent
    { echo '/skill:fix'; echo "{\"branch\":\"$branch\"}"; } \
    | timeout 300 "$ah" -n \
        ${model:+-m "$model"} \
        --max-tokens 100000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/fix/session.db \
        || true

    # push
    echo "$branch" > o/work/fix/branch.txt

    echo "==> push (fix)"
    "$cosmic" lib/work/push.tl --branch-file o/work/fix/branch.txt

    # re-check
    echo "==> check (after fix)"
    mkdir -p o/work/check

    echo '/skill:check' \
    | timeout 180 "$ah" -n \
        ${model:+-m "$model"} \
        --max-tokens 50000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/check/session.db \
        || true
done
