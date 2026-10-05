# WS7: the official conformance suite

Run protobuf's own `conformance_test_runner` against protostar for the binary, JSON and
text-format suites, keep a failure list that may only shrink, and make it a CI job.
Read the WS3, WS4 and WS5 reports first; your testee is a thin program over their work.

## Deliverables

- `conformance/testee.rb` plus the executable wrapper `conformance/run_testee` the runner
  forks: reads length-prefixed `ConformanceRequest`s on stdin, writes `ConformanceResponse`s
  on stdout, loops until EOF, never writes anything else to stdout (use stderr for logs).
  Protocol and message definitions are in `test/corpus/protobuf/conformance/conformance.proto`
  and the C++ testee `conformance_cpp.cc` next to it is the reference for the control
  flow (about 150 lines).
- Generated classes for `conformance.proto`, `test_messages_proto2.proto`,
  `test_messages_proto3.proto`, `test_messages_edition2023.proto`,
  `test_messages_editions_proto2/3` (whatever `conformance/test_protos` and
  `src/google/protobuf` hold at v36.2), produced by WS4's native emitter and committed
  under `conformance/generated/`, with a Rake task that regenerates them and a test
  that the committed files are current.
- Request handling: `protobuf_payload`, `json_payload`, `text_payload`
  (`jspb_payload` returns `skipped`); `requested_output_format` `PROTOBUF`, `JSON`,
  `TEXT_FORMAT`; `message_type` resolved through the registry; `test_category`
  `JSON_IGNORE_UNKNOWN_PARSING_TEST` turning on `ignore_unknown_fields`;
  `print_unknown_fields` for text output; parse failures answered with `parse_error`,
  serialization failures with `serialize_error`, anything unexpected with
  `runtime_error` carrying the exception message, never a crash.
- `conformance/failure_list_protostar.txt` and
  `conformance/text_format_failure_list_protostar.txt` in the runner's format (test name
  followed by `# reason`), and a Rake task `conformance:run` that invokes the runner with
  `--enforce_recommended`, `--maximum_edition 2024`, both failure lists and
  `--output_dir` for the failing-test dumps. The runner fails when a listed test
  unexpectedly passes, so the list can only shrink; keep it that way.
- `rake conformance:build`: builds the runner from protobuf's source at `v36.2` into
  `~/.cache/protostar/conformance-36.2/` with CMake (`-Dprotobuf_BUILD_CONFORMANCE=ON
  -Dprotobuf_BUILD_TESTS=OFF`, abseil fetched by the build as protobuf's CMake does;
  check `conformance/README.md` in the corpus). This needs a C++ toolchain and takes
  minutes; it is never part of `rake test`.
- CI: a `conformance` job in `.github/workflows/ci.yml` on `ubuntu-latest` that restores
  the runner from `actions/cache` keyed on the protobuf tag and the CMake flags, builds it
  on a miss, then runs `rake conformance:run`. Also run text-format conformance there.

## What to aim for

Google's own Ruby implementation fails the tests in
`test/corpus/protobuf/conformance/failure_list_ruby.txt` and
`text_format_failure_list_ruby.txt` (if present). Start from an empty list, run, and put
each failure on the list with the real reason. Then fix what WS3 and WS5 got wrong where
the fix is local and clearly right, and record in your report every failure that needs a
decision or a bigger change, grouped by cause, with the test names. The target is a list
no longer than Google's Ruby one.

## Testing without the runner

`test/conformance/testee_test.rb` drives `testee.rb` in a subprocess with hand-built
requests through the real stdin protocol for each payload kind, each output format, a
parse error and an unknown message type, so the protocol is covered on every CI Ruby
without the C++ build.

## Out of scope

Fixing the shim, performance, JSPB.
