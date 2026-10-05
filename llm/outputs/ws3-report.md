# WS3 report: the wire codec and the Message runtime

## What was built

| File | Contents |
|---|---|
| `errors.rb` | `DecodeError` (with `#offset`, message ends "at byte N"), `EncodeError`, `Protostar::TypeError < ::TypeError` |
| `wire.rb` | wire type constants, `NAMES`, `tag`, `tag_bytes`, `varint`, `varint_size`, `zigzag`, `unzigzag`, `MASK32/64`, `MAX_FIELD_NUMBER` |
| `wire/reader.rb` | `Wire::Reader`: `read_varint/tag/int32/int64/uint32/sint32/sint64/fixed32/fixed64/sfixed32/sfixed64/float/double/bytes/raw`, `skip_field`, `skip_group`, `push_limit`/`pop_limit`, `pos`, `limit`, `eof?`. String or `IO::Buffer` input, never mutated |
| `wire/writer.rb` | `Wire::Writer`: `write_varint/tag/zigzag/fixed32/fixed64/sfixed32/sfixed64/float/double/bytes/raw`, `flush`, `flush_if_full`; String target, or IO target through a 64 KiB buffer |
| `unknown_field.rb` | `UnknownField(number, wire_type, bytes)`, frozen; `bytes` are what followed the tag, verbatim; `#value`, `#to_wire` |
| `enum.rb` | `Protostar::Enum`, extended by every enum Module: `descriptor`, `lookup`, `resolve` (Symbol or String), one constant per value |
| `message.rb` | `Protostar::Message`, the base class: everything in the spec's Message API |
| `message/field_info.rb` | `FieldInfo`: the per-field plan (slot, kind, tags, classes, enum tables, default) |
| `message/coercion.rb` | type checks and conversion on write; `storable?` for container elements at encode |
| `message/accessors.rb` | readers, writers, `has_`, `clear_`, `which_` written as source and `class_eval`ed |
| `types.rb` | `Types.define`, `Types.find`, `Types::Registry`, `Types.registry` |
| `codec/decoder.rb` | entry points, `decode_delimited`, and the shared slow paths (unknown fields, maps, packed runs, nested messages) |
| `codec/decode_generator.rb` | per-class `__decode_fields` |
| `codec/encode_generator.rb` | per-class `__size` and `__write` |
| `codec/sizer.rb`, `codec/encoder.rb` | entry points and the parts the generated methods share |

Test support: `test/support/random_message.rb` (`RandomMessage.build(klass, random:, depth:, fill:, unknown:)`),
`test/support/codec_fixtures.rb` (a golden's classes, each golden in its own pool and registry),
`Oracle.pool(relative)` added to `test/support/oracle.rb`. Benchmark: `bench/codec_bench.rb`.

### How it works

- A message is one Array of slots (`@values`) plus `@unknown`. Fields with presence hold nil when unset;
  implicit-presence fields hold their value, default included (a frozen per-class template is `dup`ed on
  `new`). Repeated fields and maps are plain Arrays and Hashes, allocated on first read.
- Enum values are stored as the Symbol of the number's first name, or the Integer when the number has no
  name (open enums only). Aliases assigned by name are stored under the first name.
- Every per-class table (`__fields`, `__by_number`, `__by_name`, `__template`, `__oneofs`, `__required`) is
  a class-level instance variable, frozen and `Ractor.make_shareable` at definition time.
- All methods on message classes are compiled from source with `class_eval`: accessors, the decoder loop
  and the two encoder passes. Nothing is `define_method`ed, so everything runs in any Ractor.
- Decoding: the generated loop dispatches on the whole tag value with one `case`, inlines one- and two-byte
  varints and fixed-width reads, keeps the position in a local. Unknown fields, wire type mismatches,
  end-group tags and malformed tags fall through to `Decoder.field`.
- Encoding: `__size` records every nested message's size and every packed run's size in an identity Hash;
  `__write` emits tags as literal bytes, then unknown fields. Elements of repeated fields and maps are
  checked at encode (they are plain containers callers can push into), singular values at assignment.

## Tests

346 runs are WS3's (557 in the suite with WS1's 209 and the 2 pre-existing).

| File | Runs | Covers |
|---|---|---|
| `test/wire/varint_test.rb`, `reader_writer_test.rb` | 18 | every varint edge in the spec, negative int32/int64 as ten bytes, int32 truncation of wide varints, zigzag extremes, fixed32/64, floats and doubles with NaN (bits kept), infinities, -0.0, denormals, tags for 1 and 536870911 in every wire type, limits, skipping, IO flush, IO::Buffer |
| `test/message/types_test.rb` | 14 | define, idempotence, missing dependency error, clashes, recursion, `name:` namespaces, enum modules and aliases, shareability |
| `test/message/accessors_test.rb` | 13 | defaults, has/clear only with presence, proto3 implicit and `optional`, oneofs, enum read/write rules, containers, `[]`, `new` forms, fields named like Ruby methods |
| `test/message/type_check_test.rb` | 11 | ranges of all ten integer types, floats, single precision, strict bool, UTF-8 and transcoding, bytes, encode-time checks of containers |
| `test/message/behaviour_test.rb` | 16 | `to_h`, `==`/`eql?`/`hash`, NaN, deep `dup`/`clone`/`freeze`, inspect, unknown fields, merge semantics, `clear!`, `initialized?` |
| `test/codec/decode_test.rb` | 22 | every decode rule of the spec on unittest, unittest_proto3, map_unittest, map_proto2_unittest, unittest_proto3_optional, unittest_delimited, edition_unittest, unittest_mset, unittest_preserve_unknown_enum, test_messages_proto3 |
| `test/codec/encode_test.rb` | 11 | field order, ten-byte negatives, float specials, -0.0 without presence, maps, determinism, deep nesting, `encode_to` a StringIO and a pipe |
| `test/codec/decode_error_test.rb` | 14 | every malformation in the spec with its byte offset, recursion limit (message nesting and unknown groups) |
| `test/codec/delimited_test.rb` | 6 | delimited round trips over StringIO and a pipe, truncation, clean EOF |
| `test/codec/ractor_test.rb` | 5 | decode, encode, `new` inside another Ractor; frozen messages crossing; Ruby 4.0's `Ractor#value` guarded |
| `test/codec/property_test.rb` | 107 | every message of every golden's own file (3775 types in all goldens), 4 random instances each: `decode(encode(m)) == m`, unknown fields equal, re-encode byte-identical, sizer equals bytes written, `new(to_h) == m`, frozen decode equal and shareable |
| `test/codec/oracle_test.rb` | 109 | see below |

`bundle exec rake` clean (tests and standard). Without the oracle: 557 runs, 0 failures, 111 skips (109 of
them the oracle tests, 2 WS1's). Green on Ruby 3.4.1, 3.2.2 and 4.0.0.

## Oracle cross-check

`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1 bundle exec rake test`: 557 runs, 41903 assertions, 0 failures,
0 skips, on Ruby 3.4.1 and on 4.0.0 (google-protobuf 4.36).

For all 107 goldens (the eight files the spec names are asserted to be among them), every message of the
golden's own file, 6 random instances each, plus one hand-built edge-value TestAllTypes: our bytes decoded
by google-protobuf give our `to_h`; google-protobuf's re-encoding decoded by us gives the same `to_h` and an
`==` message. No differences were found. A deliberate mutation (sint without zigzag) fails it, so it bites.

google-protobuf's `to_h` has the same shape as ours (Symbol keys, presence fields set to their default
included, implicit zeros left out, enums as Symbols or Integers). One behaviour of the oracle differs from
protoc and is not exercised by the cross-check: it keeps unknown numbers of closed enums in the field;
we follow protoc and the spec and move them to unknown fields.

## Baseline numbers

`bench/codec_bench.rb`: proto2_unittest.TestAllTypes populated like protobuf's `TestUtil::SetAllFields`
(every singular field, two elements per repeated field), 413 bytes. Apple M-series, benchmark-ips.

| | Ruby 3.4.1 interpreter | Ruby 3.4.11 YJIT |
|---|---|---|
| protostar decode | 39 µs (25.6k/s) | 12.1 µs (82.7k/s) |
| protostar decode `frozen: true` | 53 µs | 20-40 µs (see below) |
| protostar encode | 31 µs (32.7k/s) | 9.6 µs (104k/s) |
| google-protobuf decode | 3.0 µs | 2.6 µs |
| google-protobuf encode | 0.85 µs | 0.88 µs |

Allocations per decode of that message: 76 (messages, their slot Arrays, repeated Arrays, Strings); per
encode: 6 (the identity Hash, the output String, a few `pack` buffers). Before code generation the generic interpreter decoded in 93 µs and encoded in 107 µs.
Defining classes costs about 0.35 ms per message type (unittest.proto and its imports: 66 ms), most of it
compiling the generated source.

Under YJIT, frozen decode measures 20 µs when it runs first in a process and 40 µs when plain decode ran
first; the interpreter shows no such effect. Not investigated further.

## Deviations from the spec, and why

1. **Per-class tables are class-level instance variables, not constants.** Generated code (WS4) assigns
   nested types as constants of their parent class; table constants could clash with a proto type of the
   same name. They are just as frozen and shareable.
2. **`Types.define(file, name:)`** takes a namespace Module: top-level types become its constants, nested
   types constants of their parent class (first letter capitalised, as google-protobuf does). The spec
   only says "anonymous unless `name:` is given". There is also `registry:` (default the global one) and
   `Types::Registry` for isolated sets; tests use one registry per golden.
3. **Map entry messages get no class** and are not in `define`'s result; maps decode entries directly.
4. **`Protostar::TypeError` subclasses Ruby's `TypeError`**, not `Protostar::Error`, so code written for
   google-protobuf's `rescue TypeError` keeps working. `DecodeError` and `EncodeError` are `Protostar::Error`s.
5. **Wire layout**: varint helpers and wire-type constants live in `wire.rb`, not separate `wire/varint.rb`
   and `wire/types.rb` files.
6. **`EncodeError`** is new: raised when an element pushed directly into a repeated field or map cannot be
   encoded (wrong type, out of range, unknown enum name).
7. **Additions**: `UnknownField#value` and `#to_wire`; `Enum.resolve` accepts Strings; `clone(freeze:)`;
   `to_s` aliases `inspect`; `encode_to` and `encode_delimited(io)` return the IO.
8. **Accessors that would replace a method of `Message`** (`hash`, `class`, `method`, `encode`, `freeze`,
   ...) are not defined; such fields are reachable through `[]` and `[]=`. google-protobuf, which uses
   `method_missing`, behaves the same way for these names.

## Behaviour pinned where the spec was silent

- `decode_delimited(String)` decodes the first message and ignores the rest; from an IO it returns nil at a
  clean end of input and raises on a truncated prefix or body.
- Float fields store the single-precision value on write, so a written value reads back as it will decode.
- `new(optional_float: 1e40)` stores Infinity (C's double-to-float conversion), it does not raise.
- Strings in other encodings are transcoded to UTF-8; binary and US-ASCII Strings are taken as UTF-8 bytes
  and validated. Decoded strings without `utf8_validation` keep invalid bytes, tagged UTF-8.
- Implicit-presence doubles and floats: -0.0 is written (protoc compares bits), 0.0 is not.
- Map entries always carry key and value on encode, as protoc writes them.
- A closed enum's unknown number inside a map value moves the whole entry to the map field's unknown
  fields (protoc's behaviour); inside packed runs each unknown number becomes its own varint unknown field.
- Recursion limit `n` allows `n` levels of nested messages below the top one; unknown groups count too.
- DecodeError offsets: the tag's offset for tag problems, the value's for truncation, the string's first
  byte for invalid UTF-8.
- `==` compares presence: a proto2 field set to its default differs from an unset one (protoc's
  `MessageDifferencer` does the same). Empty repeated fields equal unset ones.

## Left out

- **Extensions**: extension numbers decode as unknown fields and are re-emitted verbatim; there is no API to
  read or set them. The spec does not mention them. MessageSet items likewise stay unknown groups.
- `RepeatedField`/`Map` containers that check on push, JSON, text format, well-known types (out of scope).
- Lazy decoding and views (WS8).

## For the next workstreams

- **WS4 (generated code)**: `Types.define(file, name: SomeModule)` already places constants. Classes are
  not frozen, so reopening them to add methods works. Define dependency files first.
- **WS5 (JSON)**: reflection is `Klass.descriptor` (`Schema::Message`) plus `Klass.__fields`, an Array of
  `Message::FieldInfo` in declaration order (`name`, `symbol`, `number`, `kind`, `repeated`, `map`, `key`,
  `value`, `message_class`, `enum_module`, `enum_names`, `enum_numbers`, `presence`, `default`); `msg[name]`
  and `msg[name] = v` go through the same coercion as the writers. `__fields` is marked private API; if WS5
  wants it public, rename it (e.g. `Klass.field_infos`). `UnknownField` exposes raw bytes.
- **WS6 (google-protobuf shim)**: google-protobuf raises `RangeError` for out-of-range integers where we raise
  `Protostar::TypeError`; map that in the shim. Containers are plain Arrays/Hashes; `RepeatedField` and `Map`
  wrappers must check on push and hand back the same storage (the reader returns the stored Array, so a
  wrapper can wrap it in place). google-protobuf keeps unknown closed-enum numbers in the field; we do not.
  `has_<oneof>?` and `clear_<oneof>` are not defined. Extensions are missing (above).
- **WS8 (lazy)**: `Decoder.field` and the generated `__decode_fields(r, depth, end_group, frozen)` are the
  seams; the decoder works on a `Wire::Reader` with `push_limit`/`pop_limit`.
- **WS9 (streaming builder)**: `Wire::Writer` writes to a String or through a buffer to an IO. A nested
  message needs its length before its bytes; either build the nested message and call `__size`, or buffer.
  `Message#encode_to(io)` streams a finished message without building the whole encoding.
- The Ractor note from WS1 holds: classes and frozen messages are shareable; the registry is main-Ractor only.

## Schema changes requested

None. Nothing under `lib/protostar/schema` was modified or needed to be.

## Open questions

1. Extensions: which workstream owns them (an API to get/set by extension descriptor, MessageSet encoding)?
   WS6 needs them for google-protobuf parity.
2. Should `__fields` become public reflection API under another name for WS5 and WS6?
3. Should Arrays pushed into directly be checked on push (wrapper types) rather than at encode? The spec
   asked for plain Arrays; the cost is that a bad element is reported at encode, not at the push.
4. Is the `name:` interpretation (a namespace Module) what WS4 wants, or should it be a callable mapping
   full names to constant paths?
