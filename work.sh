#!/bin/bash
# work.sh — measure `make test` wall clock time from clean o/
# prints a single number (milliseconds) to stdout
# logs go to stderr
set -euo pipefail

cd "$(dirname "$0")"

rm -rf o/ >&2
start=$(date +%s%N)
make test >&2 2>&1
end=$(date +%s%N)
echo $(( (end - start) / 1000000 ))
