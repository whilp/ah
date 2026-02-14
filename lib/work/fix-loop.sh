#!/bin/bash
# lib/work/fix-loop.sh: retry fix/push/check up to N times if verdict is needs-fixes
set -eo pipefail

cosmic="$1"
ah="$2"
model="${3:-}"
max_retries="${4:-2}"

check_verdict() {
    local verdict
    verdict=$("$cosmic" lib/work/check-verdict.tl o/work/check/actions.json 2>/dev/null) || return 1
    echo "$verdict"
}

for attempt in $(seq 1 "$max_retries"); do
    verdict=$(check_verdict) || break
    if [ "$verdict" != "needs-fixes" ]; then
        break
    fi

    echo "==> fix (attempt $attempt/$max_retries)"

    # build fix prompt
    mkdir -p o/work/fix
    "$cosmic" lib/work/fix-prompt.tl o/work/issue.json o/work/plan/plan.md o/work/check/check.md \
        > o/work/fix/prompt.txt

    # run fix agent
    timeout 300 "$ah" -n \
        ${model:+-m "$model"} \
        --max-tokens 100000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/fix/session.db \
        < o/work/fix/prompt.txt || true

    # extract branch and push
    branch=$("$cosmic" lib/work/extract-branch.tl o/work/plan/plan.md o/work/issue.json)
    echo "$branch" > o/work/fix/branch.txt

    echo "==> push (fix)"
    "$cosmic" lib/work/push.tl o/work/fix/branch.txt

    # re-check
    echo "==> check (after fix)"
    mkdir -p o/work/check
    # rebuild check prompt using fix output if available
    do_md="o/work/fix/do.md"
    if [ ! -f "$do_md" ]; then
        do_md="o/work/do/do.md"
    fi
    "$cosmic" lib/work/check-prompt.tl o/work/plan/plan.md "$do_md" \
        > o/work/check/prompt.txt

    timeout 180 "$ah" -n \
        ${model:+-m "$model"} \
        --max-tokens 50000 \
        --unveil o/work/plan:r \
        --unveil o/work/do:r \
        --db o/work/check/session.db \
        < o/work/check/prompt.txt || true
done
