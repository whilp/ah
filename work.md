# work: reduce `make test` wall clock time

## objective
reduce the time `make test` takes from a clean `o/` directory. baseline is ~23s.

## files in scope
- Makefile (build rules, test rules, parallelism, embedding, dependency fetching)
- deps/cosmic.mk (cosmic binary pinning)
- deps/bat.mk, deps/delta.mk, deps/glow.mk (bundled tool fetching)
- lib/ah/test_*.tl (32 test files)
- sys/tools/*.tl (tool definitions compiled and embedded)

## constraints
- do not remove or skip tests unless they are genuinely not useful/valuable
- tests must still pass (`make test` must succeed)
- do not change test assertions to make them trivially pass
- focus on build/infrastructure optimizations, test runtime optimizations, and removing unnecessary work

## ideas
- version.lua is `.PHONY` — causes ah binary re-embed every time even when nothing changed. make it only regenerate when content changes (write to tmp, compare, move)
- test_envd is 10x slower than other tests (723ms vs ~50ms) — investigate why
- tests depend on `$(o)/bin/ah` which triggers full embedding + tool fetching — check if all tests actually need the ah binary or if some could run without it
- bundled bins (bat/delta/glow) are fetched as part of building ah binary — these are network fetches that add latency
- compilation step runs cosmic per .tl file — check if batch compilation is possible
- `.tl` compilation could potentially be parallelized better
- check if test summary generation adds overhead
- look for redundant or overlapping tests that could be consolidated
