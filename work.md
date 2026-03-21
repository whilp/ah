# work: reduce `make test` wall clock time

## objective
reduce the time `make test` takes from a clean `o/` directory. baseline is ~23s.

## files in scope
- Makefile (build rules, test rules, parallelism, embedding, dependency fetching)
- deps/cosmic.mk (cosmic binary pinning)
- deps/bat.mk, deps/delta.mk, deps/glow.mk (bundled tool fetching)
- lib/ah/test_*.tl (test files)
- sys/tools/*.tl (tool definitions compiled and embedded)

## constraints
- do not remove or skip tests unless they are genuinely not useful/valuable
- tests must still pass (`make test` must succeed)
- do not change test assertions to make them trivially pass
- focus on build/infrastructure optimizations, test runtime optimizations, and removing unnecessary work

## ideas
- ✓ remove `$(o)/bin/ah` dependency from test rule — tests don't use the ah binary or AH_BIN env var. verified by reading all 13 test files: none reference AH_BIN. this eliminates the entire embed pipeline (fetching bat/delta/glow, extracting cosmic skills, cosmic --embed) from the test critical path. iterations 1-10 crashed. iteration 11: minimal clean change — just remove `$(o)/bin/ah` from prereqs and `AH_BIN=...` from the command.
- version.lua is `.PHONY` — causes ah binary re-embed every time even when nothing changed. make it only regenerate when content changes (write to tmp, compare, move). (only helps incremental, not clean builds)
- test_envd is 10x slower than other tests (723ms vs ~50ms) — investigate why
- compilation step runs cosmic per .tl file — check if batch compilation is possible
- `.tl` compilation could potentially be parallelized better (already parallel via -j)
- check if test summary generation adds overhead
- look for redundant or overlapping tests that could be consolidated
- test rule depends on $(ah_lua) which includes ALL .tl files including test files themselves — could narrow to only lib sources
