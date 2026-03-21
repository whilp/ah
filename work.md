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

## critical facts
- only 2 of 32 tests use AH_BIN: test_args.tl and test_version.tl
- the other 30 tests do NOT need the ah binary at all
- the test rule currently makes ALL tests depend on $(o)/bin/ah, which triggers the full embed pipeline (fetching bat/delta/glow + cosmic --embed)
- to split this, create two test rules: one for tests needing ah binary (with $(o)/bin/ah dep), one for tests not needing it (without)
- DO NOT just remove $(o)/bin/ah from ALL tests — test_args and test_version will fail
- must use static pattern rules (not plain pattern rules) to have two different rules for the same %.tl.test.ok pattern

## ideas
- ✗ remove $(o)/bin/ah from ALL test rules — crashed 10 times because test_args.tl and test_version.tl need AH_BIN. DO NOT TRY THIS AGAIN.
- ✓ split test rules: 30 tests without ah binary dependency, 2 tests (test_args, test_version) with it. the 30 fast tests can start running immediately after compilation, overlapping with the ah binary build. (-17.2%)
- narrow test deps from $(ah_lua) to $(ah_test_dep_lua): tests depended on ALL compiled .tl files (including all 32 test files, sys/tools, bin/ah.tl). changed to depend only on lib source .lua files. this lets tests start running as soon as lib sources compile, without waiting for all other test files. — TRYING NOW (iteration 13)
- version.lua is `.PHONY` — causes ah binary re-embed every time even when nothing changed. make it only regenerate when content changes (write to tmp, compare, move). (only helps incremental, not clean builds)
- test_envd is 10x slower than other tests (723ms vs ~50ms) — investigate why
- compilation step runs cosmic per .tl file — check if batch compilation is possible
- `.tl` compilation could potentially be parallelized better (already parallel via -j)
- check if test summary generation adds overhead
- look for redundant or overlapping tests that could be consolidated
- test rule depends on $(ah_lua) which includes ALL .tl files including test files themselves — narrowing to only lib sources would reduce recompilation
- test_db has a pre-existing bug (cache_read assertion fails) — this is flaky and causes spurious failures
