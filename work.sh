#!/bin/bash
# work.sh — measure `make test` wall clock time from clean o/
# prints a single number (milliseconds) to stdout
# logs go to stderr
set -uo pipefail

cd "$(dirname "$0")"

rm -rf o/ >&2
start=$(date +%s%N)
if ! make test >&2 2>&1; then
  echo "make test failed, retrying once..." >&2
  rm -rf o/ >&2
  start=$(date +%s%N)
  if ! make test >&2 2>&1; then
    echo "make test failed twice, aborting" >&2
    exit 1
  fi
fi
end=$(date +%s%N)
echo $(( (end - start) / 1000000 ))
