#!/bin/bash
# work script: measure build time (compile .tl → .lua + embed ah binary)
# metric: wall-clock milliseconds for a clean build. lower is better.
# uses AH_PLATFORM=linux_x86_64 to avoid multi-platform network fetches.
set -euo pipefail

cd "$(dirname "$0")"

# keep deps and cosmic cached, only clean compile + embed artifacts
rm -rf o/lib o/bin/ah.lua o/bin/ah o/embed

# touch cached deps so make doesn't re-fetch them
find o/deps -type f -exec touch {} + 2>/dev/null || true
touch o/bin/cosmic 2>/dev/null || true

# measure build time
start=$(date +%s%N)
make ah AH_PLATFORM=linux_x86_64 >&2 2>&1
end=$(date +%s%N)

elapsed_ms=$(( (end - start) / 1000000 ))
echo "$elapsed_ms"
