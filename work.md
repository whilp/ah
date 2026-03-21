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
- ✓ remove `$(o)/bin/ah` dependency from test rule — tests don't use AH_BIN, so they don't need to wait for the full embed step (which includes fetching bat/delta/glow, extracting cosmic skills, and running cosmic --embed). this eliminates the embed step from the test critical path entirely. (iteration 1: crashed, re-applied iteration 2)
- version.lua is `.PHONY` — causes ah binary re-embed every time even when nothing changed. make it only regenerate when content changes (write to tmp, compare, move). (only helps incremental, not clean builds)
- test_envd is 10x slower than other tests (723ms vs ~50ms) — investigate why
- compilation step runs cosmic per .tl file — check if batch compilation is possible
- `.tl` compilation could potentially be parallelized better (already parallel via -j)
- check if test summary generation adds overhead
- look for redundant or overlapping tests that could be consolidated
- narrow test dependency from `$(ah_lua)` (all sources including other test .lua files) to just library sources — each test only needs its own compiled .lua plus the library modules, not all test .lua files. this would allow more parallelism.
