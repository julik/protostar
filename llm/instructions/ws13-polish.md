# WS13: polish, the rough edges the other workstreams reported

Every item below came out of a report under `llm/outputs/`; read the one it cites before
touching it. Each item is small on its own. Keep each as its own commit with its own
tests, and keep every existing suite green: `bundle exec rake` on Ruby 3.2.2, 3.4.1 and
ruby-4.0.0, the oracle run, `rake shim:test`, `rake conformance:run`, `rake
bootstrap:check`, `rake examples:check`, `rake conformance:check`.

## API ergonomics (WS12 report, WS6 report)

1. **`Time` into a `Timestamp` field.** Assigning a `Time` (and a `DateTime`) to a field
   whose type is `google.protobuf.Timestamp` builds the Timestamp, as google-protobuf
   does. Likewise a `Numeric` or `Rational` of seconds into a `Duration` field. Do it
   through the well-known mixins (a class-level coercion hook that `Coercion` consults
   for message-typed fields), not with special cases in the coercion code. `Builder`
   already coerces these; share the code.
2. **Short names for the well-known types.** `Protostar::Timestamp`, `Duration`, `Any`,
   `Struct`, `Value`, `ListValue`, `Empty`, `FieldMask` and the wrapper types as
   autoloaded constants that require the bootstrap file and alias the class, so
   `require "protostar"` stays cheap and `Protostar::Timestamp.from_time(Time.now)` just
   works. The long names stay.
3. **RBS that describes our classes.** `--rbs_out` alongside `--ruby_out` emits signatures
   for `Protostar::Message` subclasses: `< ::Protostar::Message`, repeated fields as
   `Array[...]`, maps as `Hash[...]`, no `_const` readers, writers typed as our coercion
   accepts. Alongside `--google_out` it keeps emitting protoc's exact RBS (the goldens
   stay). Add `sig/protostar.rbs` with the public API of `Message`, `Types`, `JSON`,
   `Text`, `View` and `Builder`, checked by `rbs validate` in CI if the `rbs` gem is a
   development dependency that installs cleanly on all four Rubies; otherwise a test
   that parses it with the gem when present.
4. **`pretty_print`.** `pp message` wraps across lines with one field per line and
   nested messages indented, like `pp` of a Hash. Views too.
5. **`to_json` with a `JSON::State`.** `JSON.pretty_generate(message)` produces indented
   output; the state's indentation is honoured by re-generating from the compact form.

## Parity and correctness (WS2, WS5, WS6 reports)

6. **Duplicate extension numbers across files.** `Schema::Pool#add` warns (to `warn`,
   once per clash) and accepts when two *different* files extend the same message with
   the same number, as protoc does; it still raises inside one file. Update the WS2
   validation test that pinned the error to pin the warning, and the compiler's
   diagnostics to carry it as a warning like protoc's.
7. **Shim `Struct.from_hash`.** The shim's `[]=` shadows the Struct mixin's, so
   `Google::Protobuf::Struct.from_hash` raises "Unknown field". Fix it so the shim's
   `Struct`, `Value` and `ListValue` behave as the gem's `well_known_types.rb` does, with
   tests from that file's semantics.
8. **Float NaN bits on the wire.** `Wire::Writer#write_float` normalises every NaN
   through `pack("e")`; write the exact 32 bits when the value is NaN so sign and payload
   survive, as doubles already do. Test both directions.
9. **`Text.print` and `Any`.** Make `expand_any` default to what protoc does
   (`protoc --decode` never expands), keep the option, and update the callers and the
   WS5 tests that assumed the opposite. The conformance text suite must stay green.

## Performance (WS3 and WS6 reports)

10. **Small-message encode.** The shim's test message encodes in 15 µs against 0.25 µs in
    the C gem, and native classes are no faster. Profile `encode` on a message with a
    few scalars and a short repeated field: look at the sizes memo, buffer growth, the
    two-pass dispatch, per-field method calls, and `Array` building in `__to_h`-style
    paths. Make the cheap wins, no semantic change; property, oracle and conformance stay
    green. Report before and after numbers from `bench/codec_bench.rb` plus a new small
    message case, on 3.4 with and without YJIT.
11. **Decode allocations.** One decode of `TestAllTypes` allocates 76 objects; see what
    is avoidable without changing the storage model and take the cheap wins.

## Hygiene (WS6, WS10 spec)

12. **`ruby -w` clean.** The generated decoders and encoders warn about unused variables
    under `-w`, dozens per file. Fix the generators, then add a CI step that runs the
    suite with `RUBYOPT=-w` and fails on any warning whose path is under `lib/`.
13. **Licences.** The shim gem gets `LICENSE.txt` (MIT) and a `THIRD_PARTY_NOTICES.md`
    carrying Google's BSD-3 notice for the descriptors embedded in its `_pb.rb` files and
    for Google's test files under `test/google/`, both in the gemspec's file list. Check
    the root gem likewise covers `lib/protostar/compiler/include/` (Google's `.proto`
    files) and `test/corpus/` in a `THIRD_PARTY_NOTICES.md`, referenced from the README.

## Assess only, with numbers in the report (WS9 report)

14. **Builder nesting cost.** Each nesting level copies its bytes into its parent. Measure
    a 50-deep and a 500-deep tree; if the cost is visible, propose the fix (a reusable
    scratch buffer with length back-patching, or a rope of chunks flushed in order) with
    an estimate, and do it only if it is under a day's work and keeps the byte-for-byte
    tests green.

## Out of scope

The lazy readers (WS11, on hold), extensions as first-class fields, new features of any
kind.
