# testing

## running tests

```sh
make ci            # tests + type checks (canonical)
make test          # tests only (incremental)
make check-types   # type checks only
```

all three are incremental — they only re-run when source files change.
results are cached in `o/`.

## test structure

test files: `lib/ah/test_*.tl`.

each test file is a standalone teal script executed by cosmic. it is run
in a temporary directory with `TEST_TMPDIR` set.

tests print lines like:
```
pass: description
fail: description
```

`lib/build/reporter.tl` collects results and produces a summary. the
make target exits non-zero if any test fails.

## writing tests

1. create `lib/ah/test_<module>.tl`.
2. require the module under test.
3. write assertions as functions that print pass/fail lines.
4. run `make test` to verify.

example pattern:

```lua
local db = require("ah.db")

-- test: open and close
local d = db.open("/tmp/test.db")
if d then
  print("pass: open")
  db.close(d)
else
  print("fail: open")
end
```

tests run in isolation. each gets its own temp directory. no test depends
on another test's state.

## type checking

`make check-types` runs the teal type checker (`cosmic --check-types`) on
every `.tl` file. type errors are collected and reported alongside test
results.

type checking and tests run in parallel during `make ci`.

## adding a new module

1. create `lib/ah/<module>.tl`.
2. create `lib/ah/test_<module>.tl`.
3. `make ci` will automatically pick up both (wildcard patterns in Makefile).
