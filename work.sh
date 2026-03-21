#!/bin/bash
# work.sh — measure `make test` wall clock time from clean o/
# prints a single number (milliseconds) to stdout
# logs go to stderr
set -uo pipefail

cd "$(dirname "$0")"

# run make test up to 3 times to handle flaky tests
for attempt in 1 2 3; do
  rm -rf o/ >&2
  start=$(date +%s%N)
  if make test >&2 2>&1; then
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
    exit 0
  fi
  echo "make test failed (attempt $attempt)" >&2
done
echo "make test failed 3 times, aborting" >&2
exit 1
