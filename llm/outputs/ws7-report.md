# WS7 report: the official conformance suite

## What was built

| File | Contents |
|---|---|
| `conformance/testee.rb` | `ProtostarConformance::Testee` (reads length-prefixed `ConformanceRequest`s, answers `ConformanceResponse`s until EOF) and `ProtostarConformance.main` |
| `conformance/run_testee` | the executable the runner forks (`#!/usr/bin/env ruby`, requires the testee) |
| `conformance/generated/**/*_pb.rb` | 7 files from `exe/protostar compile --ruby_out`: `conformance.proto`, `test_messages_proto2/3`, `test_messages_edition2023`, `test_messages_edition_unstable`, `test_messages_proto2/3_editions` |
| `conformance/failure_list_protostar.txt`, `conformance/text_format_failure_list_protostar.txt` | runner format, `# reason` comments grouped by cause |
| `script/conformance.rb` | `build`, `run [runner args]`, `regenerate`, `check`, `cmake-flags` |
| `Rakefile` | `conformance:build`, `conformance:run`, `conformance:regenerate`, `conformance:check` |
| `.github/workflows/ci.yml` | `conformance` job (below) |
| `test/conformance/testee_test.rb`, `generated_test.rb` | subprocess protocol tests and the currency test |

### How it works

- **Testee.** Looks `message_type` up in `Protostar::Types.registry` (where the generated files define
  everything); not found gives `runtime_error: "No such message type: ..."`. Payloads: `protobuf_payload` via
  `Klass.decode`, `json_payload` via `decode_json(ignore_unknown_fields: test_category == JSON_IGNORE_UNKNOWN_PARSING_TEST, registry:)`,
  `text_payload` via `Text.parse(registry:)`, `jspb_payload` answers `skipped`. Outputs: `encode`, `JSON.encode(registry:)`,
  `Text.print(unknown_fields: print_unknown_fields, registry:)`; JSPB output answers `skipped`. Protostar errors,
  `Protostar::TypeError`, `RangeError` and `EncodingError` while parsing become `parse_error`, while serializing
  `serialize_error`; anything else (no payload, UNSPECIFIED format, bugs) becomes `runtime_error` with class and
  message. Only responses go to stdout; one line of stderr at EOF. A truncated request raises (the process exits
  non-zero), as conformance_cpp.cc does.
- **Runner build.** Downloads protobuf's `v36.2` source tarball (not a git clone) into
  `~/.cache/protostar/conformance-36.2/src`, configures with
  `-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -Dprotobuf_BUILD_CONFORMANCE=ON -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_FORCE_FETCH_DEPENDENCIES=ON -Dprotobuf_INSTALL=OFF -DCMAKE_BUILD_RPATH=@executable_path|$ORIGIN`,
  builds only the `conformance_test_runner` target (Ninja when on PATH) and copies it plus `libjsoncpp*` into
  `.../bin/`. `FORCE_FETCH` makes abseil and jsoncpp come from FetchContent even when a system abseil exists.
  jsoncpp is a shared library in protobuf's CMake, so the rpath points the runner at its own directory: `bin/` alone
  is enough (checked by running with the build directory moved away), and that is all CI caches. 549 build steps,
  4 to 6 minutes on this machine. `CMAKE`, `CONFORMANCE_HOME`, `CONFORMANCE_RUNNER` override paths.
- **Run.** `--enforce_recommended --maximum_edition 2024 --failure_list ... --text_format_failure_list ... --output_dir tmp/conformance`.
  The runner runs the binary+JSON suite and then the text-format suite in one invocation; both lists are enforced in
  both directions (a listed test that passes fails the run). The whole run takes 1.5 s.
- **Regeneration.** `rake conformance:regenerate` runs `exe/protostar compile` once per include root (corpus root and
  `corpus/src`) into a temp dir and replaces `conformance/generated/`; `rake conformance:check` and
  `test/conformance/generated_test.rb` fail when the committed files differ.
- **CI.** `conformance` job on `ubuntu-latest`, Ruby 3.4: `actions/cache@v4` on
  `~/.cache/protostar/conformance-36.2/bin`, key `conformance-runner-v36.2-<os>-<sha256 of cmake-flags>`; on a miss
  `rake conformance:build`; then `rake conformance:check conformance:run`; on failure `tmp/conformance` is uploaded.
  Text format runs in the same step. Not run here (no push), so the CI job itself is untested.

## Results

Counts are from the runner on Ruby 3.4.1; 3.2.2 and 4.0.0 give the same. Binary = tests with protobuf input and
output; JSON = tests with JSON input or output. 6,558 tests in all (5,165 Required, 1,393 Recommended), across
Proto2, Proto3, Editions_Proto2, Editions_Proto3, Editions (2023) and EditionUnstable.

| Suite | Tests | Failures before fixes | Failures after |
|---|---|---|---|
| Binary | 2,835 | 5 | 1 |
| JSON | 2,814 | 26 | 0 |
| Text format | 909 | 64 | 0 |
| **Total** | **6,558** | **95** | **1** |

"Before" is after the json 3.0 fix below: without it every JSON parse failed, since `bundle install` now resolves
json 3.0.2 and WS5's parser passed it a keyword it refuses.

### Compared with Google's Ruby implementation

`failure_list_ruby.txt` at v36.2 lists 5 patterns that expand to 24 failing tests in this runner
(`FieldNameDuplicate`, `FieldNameDuplicateDifferentCasing1/2`, `Int32FieldQuotedExponentialValue.*`,
`AnyWithNoType.*`), and its testee answers `skipped` to all 909 text-format tests. We pass all 24 of those and
all 909 text tests. Our one remaining failure, `Recommended.Editions.ProtobufInput.RejectInvalidUtf8.String.Extension`,
is one Google's Ruby passes, because it has extensions. For text format, Google's C++ list has 20 patterns and
Python's 10; ours is empty.

## Fixes to other workstreams' code

Each is small, has a test, and was checked against the runner. All other tests still pass, and the oracle
cross-check is still clean (`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`: 1,941 runs, 190,107 assertions, 0 failures).

| Area | Change | Conformance tests | Test |
|---|---|---|---|
| WS5 `json/parser.rb` | Stop passing `create_additions: false` to `JSON.parse`. json 3.0 raises `ArgumentError` for it; the default is already false | every JSON input | existing JSON tests |
| WS5 `text/printer.rb`, `text.rb` | `unknown_fields: false` option leaves unknown fields out (protoc's `SetHideUnknownFields`); extensions still print by name | needed for `print_unknown_fields` | `printer_test#test_unknown_fields_can_be_hidden_while_extensions_still_print` |
| WS3 `wire/reader.rb`, `codec/decoder.rb`, `codec/decode_generator.rb` | `Reader#read_tag_varint` refuses tags longer than 5 bytes, as protoc does even when the value is small; used by generated decoders, map entries, skipped groups and `read_tag` | `Required.*.ProtobufInput.BadTag_OverlongVarint` (4) | `decode_error_test#test_tag_longer_than_five_bytes` |
| WS5 `json/parser.rb` | A field given twice is refused: by proto name and json_name (our own check), or literally twice (`allow_duplicate_key: false`, json 2.13+) | `Recommended.*.JsonInput.FieldNameDuplicate*` (12) | `decode_test#test_field_names` |
| WS5 `json/parser.rb` | Quoted integers in number form (`"1e5"`, `"1.0"`) go through a double, as protoc reads them; non-integral or out-of-range values are still refused | `Required.*.JsonInput.Int32FieldQuotedExponentialValue.*` (8) | `decode_test#test_integers` |
| WS5 `json/parser.rb`, `json/encoder.rb` | `{}` parses as an empty Any; an empty Any prints as `{}` (an Any with bytes but no URL still raises) | `Required.*.JsonInput.AnyWithNoType.*` (4) | `well_known_test#test_any_errors` |
| WS5 `json/parser.rb`, `json/encoder.rb` | Extensions as `"[full.name]"` keys, in and out, through `Text::Extensions` and the unknown fields, as the text format already does | `Recommended.*.JsonInput.FieldNameExtension.Validator` (2) | `decode_test#test_extensions_by_bracketed_name` |
| WS5 `text/tokenizer.rb`, `text/parser.rb` | Between `[` and `]`, read like protoc's tokenizer in URL mode: runs of URL characters (`A-Za-z0-9_-.~!$&()*+,;=%/`) joined across whitespace and `#` comments; prefix checked for empty and bad `%` escapes, type name for identifiers | `Required.*.TextFormatInput.AnyFieldWith{SpecialCharacters,ValidUrlPercentEscape}InTypeUrlPrefix.*` (8) | `parser_test#test_any_type_url_prefixes_take_url_characters` |
| WS5 `text/parser.rb` | Reserved field names are skipped like unknown fields (protoc's `IsReservedName`) | `Required.*.TextFormatInput.ReservedFieldName.*` (40) | `parser_test#test_reserved_field_names_are_skipped` |
| WS5 `text/parser.rb` | `\u`/`\U` escapes of surrogates are refused, paired or not | `Recommended.*.TextFormatInput.StringLiteral*Surrogate*Bytes` (16) | `parser_test#test_surrogate_escapes_are_refused` |

## What remains on the lists

`conformance/failure_list_protostar.txt`, grouped by cause:

- **No extension API in the binary codec (1).** `Recommended.Editions.ProtobufInput.RejectInvalidUtf8.String.Extension`:
  extension 133 is a `string` with UTF-8 validation, but the decoder keeps extensions as unknown fields and never
  looks at their bytes. Fixing it means the decoder must know a message's extensions, which is the extension design
  question WS3 and WS5 left open. Not a local fix.

`conformance/text_format_failure_list_protostar.txt`: empty (a comment line only).

## Decisions taken that someone may want to revisit

1. **Surrogate escapes in text format are refused.** WS5 had copied protoc, which writes `\ud800` as three CESU-8
   bytes in a `bytes` field. The suite marks refusal Recommended, and protoc's own `text_format_failure_list_cpp.txt`
   lists these tests as known failures, so I followed the suite. In `string` fields nothing changes: the bytes
   were already refused as invalid UTF-8.
2. **Duplicate JSON keys are refused**, which the gem does not do (it is on Google's Ruby list). The literal-duplicate
   check depends on the json gem: 2.13 and newer report it; older json (Ruby 3.2's default 2.6) ignores
   `allow_duplicate_key` and keeps the last value. The proto-name-versus-json_name check is ours and works everywhere.
   WS6 may want the gem's leniency in the shim.
3. **Quoted exponent integers and `{}` as Any** are now accepted, as protoc does and the gem does not. This narrows
   WS5's "where we differ from google-protobuf" list in the other direction: we now accept more than the gem.
4. **JSON extensions** reuse `Text::Extensions` (marked `@api private` under `Text`). If an extension API arrives,
   both JSON and text should move to it.
5. **`EditionUnstable`** is generated and loaded because the runner sends 4 tests of that type even with
   `--maximum_edition 2024`.

## Notes

- `cmake` was not installed on this machine. It was installed user-locally without sudo into a venv at
  `~/.cache/protostar/cmake-venv` (`pip install cmake ninja`; CMake 4.4.4). `script/conformance.rb` falls back to
  that path when `cmake` is not on PATH; Ninja is used only when on PATH.
- Git operations outside the worktree are refused in this environment, so the build fetches a tarball instead of
  cloning. CMake's FetchContent still uses git for abseil and jsoncpp.
- `conformance_cpp.cc` and `conformance/README.md` are not in the vendored corpus; I read them from the downloaded
  v36.2 source. The corpus has no `text_format_failure_list_ruby.txt`: Google's Ruby testee skips text format.
- The bundle on this machine resolves json 3.0.2 (Gemfile.lock is not committed); on main before this branch, every
  JSON parse raised. Anyone on main with a fresh `bundle install` sees that until this branch merges.

## Tests

15 new runs (1,941 in the suite). `bundle exec rake` is clean (tests and standard) on Ruby 3.4.1, 3.2.2 and 4.0.0:
1,941 runs, 0 failures, 335 skips (the oracle tests). `rake conformance:run` passes on all three.

| File | Runs | Covers |
|---|---|---|
| `test/conformance/testee_test.rb` | 7 | `run_testee` in a subprocess through the real framing, with classes from the corpus goldens: each payload kind (binary, JSON, text) to each output format (9 requests to one process); proto2 and editions types; `ignore_unknown_fields` per test category; `print_unknown_fields`; parse errors for each payload kind, unknown message type, JSPB in and out, UNSPECIFIED format, missing payload, a JSON serialize error; empty input; a truncated request exits non-zero |
| `test/conformance/generated_test.rb` | 2 | committed generated files equal what `protostar compile` writes; exactly the 7 expected files |
| tests named in the fixes table | 6 new, 3 changed | as listed |

## Open questions

1. Who owns extensions (WS3's and WS5's open question)? The last failure needs the decoder to know them.
2. Should the shim (WS6) restore the gem's leniency on duplicate JSON keys, or keep the stricter reading?
3. Should `Gemfile.lock` be committed, or json pinned, so a fresh bundle cannot break JSON parsing again?
