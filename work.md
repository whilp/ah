# work: reduce build time for `make ah`

## objective
reduce wall-clock time for `make ah AH_PLATFORM=linux_x86_64` from a clean
compile state (deps and cosmic pre-cached). baseline: ~65s (highly variable
60-80s due to I/O scheduling on 2 cores).

## context
- 2 CPUs available, make already uses `-j$(nproc)`
- 36 .tl files compiled for `make ah` (27 lib + 2 dep + 7 sys/tools)
- each `cosmic --compile` invocation costs 0.4-3.2s wall-clock
  - loop.tl: 3.2s, tools.tl: 2.4s, sandbox.tl: 1.6s, compact.tl: 1.5s
  - init.tl: 1.5s, db.tl: 1.4s, sys/tools/read.tl: 1.1s, sys/tools/bash.tl: 1.0s
- embed step: ~3.4s
- cosmic skill extraction: ~0.07s
- user CPU is ~10s but wall-clock is ~65s (process startup overhead, I/O)

## files in scope
- `Makefile` — build rules, parallelism, recipe structure
- `deps/cosmic.mk` — cosmic dep definition
- `deps/bat.mk`, `deps/delta.mk`, `deps/glow.mk` — tool dep definitions

## constraints
- no functionality changes — output binary must be identical
- `make ci` must still pass
- don't modify .tl source files (optimization is in build system only)
- don't change the cosmic compiler itself

## ideas
- [ ] reduce `mkdir -p` overhead: pre-create all output dirs in one recipe
      before compiling (avoids 36 separate mkdir calls)
- [ ] combine compile + staging: compile .tl directly to embed path instead
      of compiling to o/lib/ then copying to o/embed/ (eliminates ~30 cp calls)
- [ ] order-only prerequisites for directories: use `| $(dir)` pattern to
      avoid redundant mkdir
- [ ] batch compilation: check if cosmic supports compiling multiple .tl
      files in one invocation (would reduce process startup overhead)
- [ ] reduce embed staging copies: use symlinks instead of cp for staging
- [ ] lazy cosmic skill extraction: make stamp check more granular
- [ ] avoid redundant .PHONY version.lua rebuild: only regenerate if
      version actually changed
