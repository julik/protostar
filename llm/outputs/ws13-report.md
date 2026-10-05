# WS13 report: polish

Fourteen items from the other workstreams' reports, in the spec's order, one commit each (item 11 has a
follow-up commit, see below). Nothing pushed or merged.

## The items

| # | Item | Status | What landed |
|---|---|---|---|
| 1 | `Time` into Timestamp, Numeric into Duration | done | `Message.__coerce` class hook, consulted by `Coercion.single` for message fields; the Timestamp and Duration mixins override it. `WellKnown::Timestamp.parts` / `Duration.parts` are shared with `Builder` (its own copy removed) |
| 2 | Short names | done | `Protostar::Timestamp`, `Duration`, `Any`, `Struct`, `Value`, `ListValue`, `Empty`, `FieldMask`, 9 wrappers: `autoload`ed from `lib/protostar/short_names/*.rb`, which require the bootstrap file and alias. `require "protostar"` loads no `_pb.rb` |
| 3 | RBS for our classes | done | `Emitters::ProtostarRbs`; CLI/plugin use it for `--rbs_out` next to `--ruby_out`; `sig/protostar.rbs` (public API) plus generated `sig/protostar/google/protobuf/*_pb.rbs`; `rbs >= 3.5` dev dependency, `rake rbs:validate` in CI, a test validating sig/ and every corpus file's signatures |
| 4 | `pretty_print` | done | messages and views lay out as a pp group: one line when it fits, else a field per line, nested messages indented |
| 5 | `to_json` with a `JSON::State` | done | `JSON.layout` re-lays the compact JSON token by token with the state's indent/space/newlines/depth; numbers keep their spelling |
| 6 | Cross-file extension numbers | done | `Pool#add` warns once per clash and keeps the first; still raises within one file; WS2 deviation removed |
| 7 | Shim `Struct.from_hash` | done | gem's Struct/Value/ListValue methods moved to `Internal::WellKnown`, included after `MessageMethods` |
| 8 | Float NaN bits | done | `Wire.float_nan` / `pack_floats` used by the writer, generated encoders, Builder and `Coercion.float32` |
| 9 | `Text.print` and Any | done | `expand_any: false` by default; option kept |
| 10 | Small-message encode | done | packed runs sized and written inline; two-byte varints inline |
| 11 | Decode allocations | done (none avoidable) | allocations analysed; packed varint runs decoded in a generated per-field loop, packed fixed runs without an interpolated directive |
| 12 | `ruby -w` clean | done | generators fixed; `rake test:warnings` replaces `rake test` in CI's test job |
| 13 | Licences | done | shim `LICENSE.txt` + `THIRD_PARTY_NOTICES.md`; root `THIRD_PARTY_NOTICES.md`; both gemspecs and READMEs |
| 14 | Builder nesting cost | assessed, not fixed | linear to 100 levels at small payloads; quadratic copying shows past that. Fix estimated at about a day, see below |

## Tests

| Suite | Start | End |
|---|---|---|
| `bundle exec rake` on 3.2.2, 3.4.1, ruby-4.0.0 | 2,302 runs, 335 skips | 2,330 runs, 99,480 assertions, 0 failures, 335 skips (same skips); standard clean |
| oracle (`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`) | | 2,330 runs, 245,637 assertions, 0 skips |
| `rake test:warnings` on 3.2.2, 3.4.1, 4.0.0 | (new) | no warnings from lib/; putting back the one encoder line it fixed gives 838 |
| `rake shim:test` | 992 tests, 45 omissions | 997 tests, 0 failures, 45 omissions |
| `rake conformance:run` | | binary/JSON 5,648 passed, 1 expected failure; text 909 passed |
| `bootstrap:check`, `examples:check`, `conformance:check`, `rbs:validate` | | pass |

New tests: `test/well_known/time_test.rb` (+3), `test/well_known/short_names_test.rb` (3, one in a subprocess),
`test/emitters/protostar_rbs_test.rb` (5: exact output, accessors equal the runtime's, no package/no types,
bootstrap current, `rbs validate` over sig/ and all 98 corpus files in 3 batches of non-clashing Ruby constants),
CLI and plugin RBS selection (+2), `test/message/pretty_print_test.rb` (3), `test/json/pretty_test.rb` (4, layout
fuzzed against the stdlib generator), `test/schema/pool_test.rb` (2 replacing 1), `shims/.../test/shim/well_known_test.rb`
(5), `test/wire/float_nan_test.rb` (5), printer test assertions for the Any default, packed-run error cases in
`decode_error_test.rb`, `test/licence_test.rb` (2).

## Performance (items 10, 11)

`bench/codec_bench.rb` now has a small message next to TestAllTypes: `bench.Small` (proto3, int32, int64, string,
bool, double, a nested message, an enum, and 20 packed int32s; 50 bytes), with google-protobuf's numbers under the
oracle. Apple M-series, benchmark-ips, per operation. "Before" is this branch just before item 10.

| | 3.4.1 interpreter, before | after | 3.4.11 YJIT, before | after |
|---|---|---|---|---|
| TestAllTypes decode | 39.3 µs | 39.2 µs | 13.8 µs | 12.9 µs |
| TestAllTypes decode frozen | 52.4 µs | 52.4 µs | 40.7 µs | 39.8 µs |
| TestAllTypes encode | 30.1 µs | 27.2 µs | 9.45 µs | 8.57 µs |
| small decode | 7.10 µs | 4.84 µs | 3.26 µs | 2.27 µs |
| small encode | 11.3 µs | 5.27 µs | 3.48 µs | 1.31 µs |
| google-protobuf small decode / encode | 0.93 / 0.21 µs | | 0.82 / 0.20 µs | |
| google-protobuf TestAllTypes decode / encode | 2.80 / 0.87 µs | | 2.58 / 0.87 µs | |

The shim's `BasicTest::TestMessage` (WS6's 15 µs encode, 11 µs decode) now encodes in 6.3 µs and decodes in 5.2 µs
on 3.4.1.

What the profile showed, and what was done:

- **Encode.** Most of a small encode was `Sizer.packed`: a `Coercion.storable?` call (a `case` and a
  `Range#cover?`) and a `Wire.varint_size` call per element, then a `write_varint` call per element in
  `Encoder.packed`. The generated `__size`/`__write` now check, size and write packed elements inline with the same
  checks and errors; varints under 0x4000 are sized and written without a call. The sizes memo
  (`{}.compare_by_identity`, 0.09 µs), buffer growth (capacity is preallocated from the size pass) and `flush_if_full`
  were measured and are not worth changing. What is left is the two passes over every declared field: 3 µs per pass
  for the 153 fields of TestAllTypesProto3 even when one is set. Removing it needs a one-pass encoder; not cheap.
  A `while` loop instead of `each` in the generated loops was tried and measured no faster on 3.4; not kept.
- **Decode allocations.** One TestAllTypes decode allocates 76 objects: 18 messages and their 18 slot Arrays, 25
  repeated-field Arrays, 13 field Strings and the Reader (75; the tracer puts the 76th in Ruby itself). None goes without
  changing the storage model. Cheap wins elsewhere: packed varint runs are read by a generated
  `__decode_packedN` per packable varint field instead of a `Decoder.scalar` call per element, and packed fixed runs
  unpack with a frozen directive (TestPackedTypes decode: 16 to 13 objects). The loop first went inline into
  `__decode_fields`; YJIT then ran the small decode slower (3.05 to 3.55 µs) though a one-field message got faster,
  so it moved to its own method (commit `b08dda7`).

## Item 14: Builder nesting cost

A chain of `Node { name, payload, child }` built with `Protostar::Builder` (each level a block), against
`Message#encode` of the same tree; bytes compared equal. 3.4.1 interpreter unless noted. Per-level time is the
total divided by the depth, so a flat number means linear cost.

| depth | bytes (100 B payload) | builder, per level | encode, per level | builder per level, 1 KB payload | builder per level, YJIT |
|---|---|---|---|---|---|
| 10 | 1,116 | 2.58 µs | 0.80 µs | 3.15 µs | 1.20 µs |
| 50 | 5,596 | 2.62 µs | 0.76 µs | 3.83 µs | 0.77 µs |
| 100 | 11,196 | 2.68 µs | 0.74 µs | 6.59 µs | 0.76 µs |
| 500 | 56,349 | 3.16 µs | 0.86 µs | 9.30 µs | 1.20 µs |
| 1000 | 112,849 | 6.24 µs | 0.87 µs | 14.58 µs | 4.68 µs |

Allocations are 5 objects per level (a child Writer and its String per open level; the spare list cannot help
while every level is open). At 50 levels the copying does not show. It shows past 100 levels, or at 100 with large
payloads (2× per level at 1 KB a level). protostar's and Google's decoders refuse more than 100 levels by default,
so trees deep enough to suffer cannot be decoded without raising `recursion_limit`.

Proposed fix, not done: a rope. Each open level keeps a list of chunks instead of one String; when a child closes,
the parent appends the tag and length bytes, then the child's chunks by reference; the top level joins (or, for an
IO, writes) the chunks once at the end. To keep shallow trees (the common case, 2 to 3 levels) from paying for
retained chunks, only children above a threshold (say 4 KiB) are linked; smaller ones are copied as now. Back-patching
a reserved length in one scratch buffer does not help: a minimal varint length of unknown width means shifting the
child's bytes anyway, and padded varints would break the byte-for-byte tests. Estimate: about a day (the buffer
switch touches `__nested`, `__map`, packed runs, `cache!`/`encoded!` fragments and IO streaming in an 800-line file),
with the existing 177 builder tests as the net. Not done: it is at the spec's one-day limit and only helps trees
past the default recursion limit.

## Deviations and decisions

1. **Item 1** also accepts a `Date` (as Builder already did); RBS writers say `::Time` only (`::Date` needs the
   `date` library's signatures). An out-of-range or non-finite Duration raises `Protostar::TypeError` ("expects a
   finite value in google.protobuf.Duration's range"). The shim keeps its own conversion (`Internal::Convert`), which
   follows the C gem's float rounding for Duration.
2. **Item 2**: `Struct` inside `module Protostar` is now the message class, so the compiler's three `Struct.new`
   became `::Struct.new`. Code reopening `module Protostar` and saying bare `Struct` (or `Value`, `Any`, ...) will
   hit the autoload. Autoload in a non-main Ractor is subject to Ruby's rules for `require` there.
3. **Item 3**: `--rbs_out` alone, or with `--google_out`, still writes protoc's RBS (the goldens are untouched);
   with `--ruby_out` it writes protostar's, and the editions refusal (protoc's) applies only to protoc's flavour.
   The plugin follows the same rule (`ruby,rbs`). `initialize` takes the init Hash and typed keywords. Field
   accessors are left out exactly where the runtime leaves them out (`Message::Accessors.reserved`). Signatures
   for `Builder`'s per-message field methods are not generated (they are made at runtime per root class).
   `sig/**/*.rbs` is now in the gem.
4. **Item 5**: re-laying tokens rather than `JSON.parse` + regenerate, because a parse round trip changes number
   spelling (`1e+300` to `1.0e+300`) and loses `-0`. Matches the stdlib C generator's layout, including its rule of
   indenting closing brackets only when the newline string is non-empty.
5. **Item 6**: `Pool#add(file, warn: true)`; the compiler, its output pool and the plugin pass `warn: false`
   because the linker already reports protoc's warning as a diagnostic (CLI prints it on stderr like protoc).
6. **Item 7**: the gem defines these helpers only after `require "google/protobuf/well_known_types"`; the shim now
   has them from class setup on, a superset.
7. **Item 8**: a signalling float NaN comes back quiet: Ruby's own float-to-double read (`unpack("e")`) sets the
   quiet bit before protostar sees the value. Quiet NaNs keep sign and payload exactly.
8. **Item 9**: the conformance testee keeps the default (now unexpanded); both suites stay green.
9. **Item 12**: the CI step replaces the test job's plain `rake test` (it runs the same suite and also fails on
   test failures), so the suite is not run twice. With `RUBYOPT=-w`, subprocess tests that assert an empty stderr
   also fail on our warnings, which is a second net.
10. **Item 13**: the notices cover the bootstrap `_pb.rb`/`_pb.rbs` (generated from, and carrying comments of,
    Google's `.proto` files) and the shim files that follow the gem's Ruby code, beyond what the spec listed.

## For the next workstreams

- Bootstrap: `rake bootstrap:regenerate` now also writes `sig/protostar/google/protobuf/*_pb.rbs`.
- `Message.__coerce(value)` is the hook for other message types that want Ruby values assigned (return a message
  or nil; raise `RangeError` for a value of the right kind out of range).
- `bench/codec_bench.rb` measures the small message; `script/warnings.rb` is the `-w` gate.
- Item 14's rope is the open performance item for the Builder; the encoder's remaining fixed cost is the two
  full passes over declared fields.

## Open questions

1. Should `Message.__coerce` become public API (`Klass.coerce`) for user-defined conversions?
2. Should the shim's Duration conversion move to protostar's exact rounding (`Rational`) rather than the C gem's
   float arithmetic? The differential probes pin the gem's today.
3. Builder rope (item 14): worth a day now, or only when someone needs trees deeper than 100?
