# Run the test suite in parallel

**Status:** feature lead from Julik, 2026-10-06. Small-to-medium, not scheduled.

## Today (measured on main, Ruby 3.4.1, 10 cores)

`bundle exec rake test` runs 2,351 tests serially in about 90 s of wall time. Rough time
per directory, each run alone:

| Directory | Seconds |
| --- | ---: |
| `test/emitters` | 22.4 |
| `test/bootstrap` | 13.5 |
| `test/text` | 11.0 |
| `test/view` | 10.4 |
| `test/compiler` | 9.4 |
| `test/builder` | 8.7 |
| `test/codec` | 8.3 |
| `test/cli` | 6.7 |

The suite also runs three more times per review (three Rubies), once with the oracle, and
the shim's 997 tests in their own bundle. Ten cores sit idle for all of it.

## What could step on what

Counted on main:

- 5 test files touch the process-global registry or pool (`Protostar.generated_pool`,
  `Types.registry`, `Types.define` on the global). Two parallel tests defining the same
  file into the global registry collide.
- 6 files use temp directories or `tmp/` (the CLI, examples, bootstrap, release and
  conformance tests); `tmp/` paths with fixed names are shared.
- 1 file sets `ENV` (the oracle switch); process-wide.
- 5 files start Ractors; Ractors in one process are fine in parallel but noisy with
  warnings.
- 9 files spawn subprocesses, start a TCP server on a free port, or run the CLI; the
  port and the spawned processes are per test already, the `tmp/` outputs may not be.
- Class definition from goldens (`CodecFixtures.load`) is memoised in a process-wide Hash;
  under threads that is a race, under processes it is just repeated work.

## Approach

Processes, not threads: `minitest`'s `parallelize_me!` runs tests in threads of one
process, which keeps the global registry shared and makes the Ractor and `ENV` tests
unsafe. Minitest has no built-in process forking; use the `minitest-parallel_fork` gem
(forks N workers, each runs a shard of the test files; pure Ruby, development dependency
only) or a 40-line runner in `test/parallel.rb` that forks once per core, hands each child
a slice of the test files, and merges the Minitest reports through a pipe. The small
runner is preferable: no dependency, and it can shard by *file*, which is what the
isolation rules below need. `rake test` keeps the serial path (`PARALLEL=0` or
`TEST=one_file`) for debugging and for `test:warnings`, which must see every warning once.

Isolation rules, each enforced by a test support helper so that a new test cannot break
them by accident:

1. **Temp dirs are allocated, never named.** `TestSupport.tmpdir` wraps `Dir.mktmpdir`
   under `tmp/test/<pid>/` and removes it in `teardown`; a grep test fails on any literal
   `tmp/` or `/tmp/` path in `test/` outside that helper. The conformance and bootstrap
   checks that compare against committed files read from the repo and write to a tmpdir.
2. **Registries are per test.** Tests that define classes use `Types::Registry.new` and
   `Schema::Pool.new` through `CodecFixtures.load(…, registry:)`; the five files on the
   global get moved over. The fixtures cache becomes per registry (or per process, which
   sharding by file makes harmless). The `registries-not-global.md` brief makes this the
   natural shape anyway.
3. **`ENV` is read at boot, not toggled.** The oracle switch becomes a constant computed
   once in `test_helper.rb`; no test assigns `ENV`.
4. **Ports are free ports** (`TCPServer.new("127.0.0.1", 0)`), already the case; the helper
   makes it the only way.
5. **Subprocess outputs go to the test's tmpdir**, never to `tmp/` directly.
6. **Ractor tests** run in their own shard (a file-name rule, `*_ractor_test.rb`) so their
   warnings and their eager-load needs (see `autoload-everything.md`) stay contained.
7. **The fixture goldens are read-only**; a test asserts nothing under `test/corpus/` is
   modified after the run (mtime check in an `at_exit`), which also catches a stray
   `rake corpus:goldens`.

Sharding: by file, longest-first using the per-directory timings above recorded into
`test/.timings` by each run (the way `parallel_tests` balances), so `test/emitters` does
not land on one worker at the end. Expected wall time on 10 cores: the longest shard,
about 15 to 20 s, from 90 s.

The shim suite is `test-unit`, which has its own parallel runner via `--jobs`; apply the
same tmpdir and port rules there and turn it on. The release test, the conformance run and
the pbbuilder suites stay serial; they are subprocess-heavy and short.

## Tests of the tests

- The isolation helpers above with their grep and mtime guards.
- A `rake test` run with `PARALLEL=1` and `PARALLEL=0` producing the same counts.
- CI switches to the parallel run on the four-Ruby matrix; the warnings job stays serial.

## Effort

Small-to-medium: the runner is short; moving the five global-registry files and the six
tmp users onto the helpers is the real work, plus the timing file and the shim's `--jobs`.
