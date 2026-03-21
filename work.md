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
- must use static pattern rules (not plain pattern rules) to have two different rules for the same %.tl.test.ok pattern
- tools.tl falls back to loading from o/sys/tools/ when /zip/embed/sys/tools doesn't exist (line 194), so tests DO need compiled sys/tools

## ideas
- ✗ remove $(o)/bin/ah from ALL test rules — crashed 10 times because test_args.tl and test_version.tl need AH_BIN. DO NOT TRY THIS AGAIN.
- ✓ split test rules: 30 tests without ah binary dependency, 2 tests (test_args, test_version) with it. the 30 fast tests can start running immediately after compilation, overlapping with the ah binary build. (-17.2%)
- narrow test deps from $(ah_lua) to $(ah_test_deps) — TRYING iteration 5. defined `ah_test_deps` as `$(patsubst %.tl,$(o)/%.lua,$(ah_lib_srcs) $(ah_dep_srcs) $(wildcard sys/tools/*.tl))`. this removes bin/ah.lua and ~32 test .lua compilations from the prerequisite list, so each test only waits for its own .lua + the library/dep/tools files. previous attempts (iterations 3-4) crashed — likely variable name or definition issues. this time defined the variable right after ah_dep_lua using only well-established source variables.
- version.lua is `.PHONY` — causes ah binary re-embed every time even when nothing changed. make it only regenerate when content changes (write to tmp, compare, move). (only helps incremental, not clean builds)
- test_envd is 10x slower than other tests (723ms vs ~50ms) — investigate why
- compilation step runs cosmic per .tl file — check if batch compilation is possible
- `.tl` compilation could potentially be parallelized better (already parallel via -j)
- check if test summary generation adds overhead
- look for redundant or overlapping tests that could be consolidated
- test_db has a pre-existing bug (cache_read assertion fails) — this is flaky and causes spurious failures
- replace `cosmic --test $@ cosmic $<` with `cosmic $< && touch $@` to eliminate one process spawn per test (32 tests * ~50ms = potential small saving)
