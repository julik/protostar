# Pure-Ruby MEGAULTRA codec optimisation: make protostar go brrrrrrr

**Status:** feature lead from Julik, 2026-10-06. Not scheduled. The target is parity with the
google-protobuf C extension, however unlikely; the honest goal is to close most of the gap
and know exactly where the rest is.

## Where we stand (docs/benchmarks.md, 2026-10-06, Ruby 3.4.11, M1 Pro)

| | protostar | protostar, YJIT | C extension | gap, YJIT vs C |
|---|---:|---:|---:|---:|
| decode TestAllTypes, 413 B | 42.9 µs | 30.5 µs | 3.07 µs | 10× |
| encode TestAllTypes | 30.0 µs | 11.9 µs | 0.92 µs | 13× |
| decode small, 50 B | 5.26 µs | 2.54 µs | 1.09 µs | 2.3× |
| encode small | 5.76 µs | 3.57 µs | 0.27 µs | 13× |
| 1,000 friends, new + encode | 17.6 ms | 7.3 ms | 1.8 ms | 4× |
| define 160 classes | 176 ms | 181 ms | 0.54 ms | 330× |

Known leads already written down: `yjit-polymorphic-call-sites.md` (YJIT loses 3× once many
classes have run; shared helper call sites go megamorphic), WS13's note that encode is two
full passes over every declared field, WS3's 76 allocations per `TestAllTypes` decode.

## The ceiling, so we aim at the right thing

A protobuf decode is a byte loop. In pure Ruby the floor is set by how fast the VM can
`getbyte`, branch on a tag, and store a value: roughly 30 to 60 ns per field under YJIT,
against about 5 ns in C. For `TestAllTypes` (about 70 field occurrences) that is 2 to 4 µs,
which puts the realistic YJIT target at 3 to 5 µs decode and 2 to 4 µs encode, within 2× of
the C extension's 3.07 and 0.92 µs. Interpreter targets are about 3× looser. "Parity" is
only on the table for the paths that need no per-field work: zero-copy views (already faster
than C for partial reads), and whatever the thin native codec brief (`thin-native-codec.md`)
takes over.

## The benchmark harness we need first

Numbers steer this work, so the harness comes before any optimisation:

1. **Shapes.** Add to `bench/fixtures.rb`: `TestAllTypes` (every kind), a 50-byte "RPC
   request", a 1 KB "API response" with nested messages and a repeated field of 20, a
   10 KB message dominated by strings, a 100 KB message dominated by packed numbers, a map-
   heavy message, a 1,000-element repeated sub-message list, a deeply nested (50 levels)
   message, and a 1 MiB blob message. Each both as a Ruby object and as bytes.
2. **Operations** per shape: `decode`, `decode(frozen: true)`, `encode`, `new(hash)`,
   `to_h`, `==`, `dup`, and for repeated fields `each` over the decoded result. Views and
   `Builder` keep their own tables.
3. **Three columns per operation**: protostar interpreter, protostar YJIT, C extension; and
   a fourth, "allocations per call", from `GC.stat(:total_allocated_objects)` deltas, since
   allocation is where pure Ruby loses most.
4. **Process states**: fresh process versus after loading the whole corpus (the YJIT cliff
   from the polymorphism lead); report both.
5. **Profiles on demand**: `BENCH_PROFILE=stackprof` (wall and object modes) and
   `BENCH_YJIT_STATS=1` writing `RubyVM::YJIT.runtime_stats` (exits, megamorphic sites,
   side exits per method), to `tmp/bench/`. `stackprof` as a development dependency.
6. **A regression gate** separate from `rake bench`: `rake bench:guard` runs the small and
   `TestAllTypes` rows against numbers committed in `bench/baseline.json` and fails on a
   >15% regression on the same machine class; opt-in in CI on a labelled runner, always run
   before merging anything under `lib/protostar/codec/`.
7. Every change in this workstream lands with the before-and-after table in its commit.

## Where the time goes, and the moves

Measured leads first, in the order the harness will probably rank them:

- **Megamorphic helpers under YJIT.** Inline the varint read and write, tag dispatch and
  fixed-width reads into each generated method instead of calling `Wire::Reader` and
  `Writer`; give each class private copies of anything still shared. Expected: the 3× cliff
  disappears and the fresh-process numbers become the steady state.
- **Two-pass encode.** Replace sizer-then-writer with a single pass that writes nested
  messages into a scratch buffer and back-patches lengths, or writes children first into a
  rope and emits lengths from their sizes. Expected: encode close to halves.
- **Allocation per decode.** 76 objects for `TestAllTypes`: the slot Array, the presence
  bitmask Integer when it grows past 62 bits, one String per string field (unavoidable),
  Arrays for repeated fields, Hashes for maps, and the message objects. Pre-size Arrays
  from a field count, avoid intermediate Arrays in packed decoding, keep bignum presence out
  of the common path, decode `bytes` and `string` with one `byteslice` each, intern
  repeated enum Symbols from a frozen table.
- **Tag dispatch.** One `case` on the whole tag Integer already; check whether a
  precomputed jump table (Hash of tag to method) beats `case` for messages with many
  fields, and whether ordering `when` branches by field number helps the common path
  (protoc writes in number order).
- **Varints.** Unroll the one- and two-byte cases inline (partly done); for the 64-bit
  cases use `unpack1("w")`? No: BER is not LEB128. Benchmark a lookup-table approach
  versus the loop for 3 to 5 byte varints, which dominate int64 timestamps and sizes.
- **Strings.** `byteslice` plus `force_encoding(UTF_8)` plus `valid_encoding?` per string
  field: measure `unpack1("U*")`-free validation, and skip validation when
  `utf8_validation?` says `NONE`.
- **Object construction.** `allocate` plus direct ivar stores instead of `new` with keyword
  parsing in the decoder (check what the generator does today); `frozen: true` should not
  cost 30% more than a plain decode.
- **Class definition** (176 ms for 160 classes, 330× the C extension): most of it is
  `class_eval` of generated source. Cache the generated source per descriptor hash on
  disk (`~/.cache/protostar/codegen/`) or emit it into the generated `_pb.rb` so loading a
  generated file is `require` speed; the emitter already knows everything the generator
  needs. This is the biggest multiplier in the table and the easiest to make vanish.
- **YJIT specifics**: avoid `send`, `instance_variable_get`, splats and block
  `yield` in hot generated code; prefer `while` over `each`; keep methods small enough to
  compile; check `RubyVM::YJIT.runtime_stats[:side_exit_...]` after each change.
- **Ruby version features**: `IO::Buffer` for bulk fixed-width reads on 3.2+, `String#byteindex`,
  `Array#pack` with buffer reuse (`buffer:` keyword) for the writer, and in Ruby 3.4+
  whatever the string-scanning primitives offer; all behind feature checks, pure Ruby only.

## Acceptance

- The property, oracle and conformance suites stay green after every move; byte-identical
  output is non-negotiable.
- `docs/benchmarks.md` regenerated with the new harness; the gaps above halved at least on
  the YJIT column, with the remaining gap explained per row in the report.
- Class definition under 20 ms for the 160-class case (from 176 ms).
- No new dependencies at runtime; `stackprof` in the development group only.

## Effort

Large, and open-ended by nature. Run it as its own workstream with the harness as its
first deliverable and a stop rule: when a week of work moves a row by under 10%, the
remaining gap belongs to the thin native codec.
