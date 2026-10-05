# WS3: the wire codec and the Message runtime

Encode and decode protobuf binary for messages described by `Protostar::Schema`, with
message classes that are pleasant to use from Ruby and safe to share between Ractors.
Read `ws1-descriptor-model.md` and `llm/outputs/ws1-report.md` first; descriptors are
your only input. Phase 1 is fully eager: decoding materialises every field. There are no
lazy cells and no views; those are WS8.

## Deliverables

`lib/protostar/wire/` (varint, reader, writer, wire types), `lib/protostar/message.rb`
and `lib/protostar/message/` (the base class, class definition from descriptors, field
storage, accessors, unknown fields, equality, inspect, hashes in and out),
`lib/protostar/enum.rb`, `lib/protostar/types.rb` (defining and finding classes),
`lib/protostar/codec/` (decoder, encoder, sizer), errors in `lib/protostar/errors.rb`.
Tests under `test/wire/`, `test/message/`, `test/codec/`, plus
`test/support/random_message.rb` (a generator later workstreams reuse).

## Defining classes

```ruby
types = Protostar::Types.define(schema_file)      # => frozen Hash full_name => Class or Module
Person = types.fetch("acme.Person")
Color  = types.fetch("acme.Color")                 # an enum Module
Protostar::Types.find("acme.Person")              # global registry, Mutex-guarded
```

`Types.define` defines every message and enum of a file together, so recursive and
mutually recursive types link. A file's dependencies must have been defined first (the
registry is consulted for cross-file references); raise `Protostar::Error` naming the
missing file otherwise. Each class is a subclass of `Protostar::Message` with
`descriptor` (the `Schema::Message`), and every per-class table (field index to Class for
message fields, field index to enum Module, accessor metadata) is a frozen constant built
at definition time so the class is `Ractor.shareable?`. Classes are anonymous unless
`name:` is given; WS4's generated code assigns them to constants. Enum Modules have one
constant per value (aliases included), `descriptor`, `lookup(number)` returning the first
Symbol declared for that number or nil, `resolve(symbol)` returning the number or nil,
and are frozen.

## Message API

- `Klass.new`, `Klass.new(hash_with_symbol_or_string_keys)`, `Klass.new(**fields)`.
  Unknown keys raise `ArgumentError`. Nested hashes build nested messages; Arrays build
  repeated fields; Hashes build maps.
- One accessor pair per field: `name` and `name=`. `has_name?` and `clear_name` exist
  only for fields with `presence?`; `has_` on other fields is not defined. For a oneof
  `which_<oneof>` returns the Symbol name of the set field or nil, and setting any
  member clears the others. Enum readers return a Symbol, or an Integer when the number
  has no name; writers accept a Symbol (must exist) or an Integer (any value for open
  enums, must exist for closed ones). Repeated fields are plain Arrays, maps are plain
  Hashes; the writer copies and checks every element, and the reader hands back the
  stored container.
- Type checking on write raises `Protostar::TypeError`: Integer range per type (int32,
  uint32, sint32 and the 64-bit forms; wrap nothing, reject), Float accepts Integer,
  `bool` is strict, `string` must be valid UTF-8 (transcode from other encodings, reject
  invalid bytes), `bytes` is stored as a frozen binary String, message fields accept
  only the right class or a Hash, nil clears.
- `[]`, `[]=` by field name (String or Symbol), `to_h` (Symbol keys; every field that is
  set or non-default; nested messages as hashes; enums as Symbols), `==` and `eql?`
  (same class, same field values, unknown fields ignored, NaN == NaN for float
  fields as protoc's `MessageDifferencer` treats them), `hash`, `dup` and `clone` (deep),
  `freeze` (deep, after which the message is `Ractor.shareable?`), `inspect` as
  `#<acme.Person name: "x", ids: [1, 2]>` in field order showing set and non-default
  fields only, `unknown_fields` (frozen Array of `UnknownField(number, wire_type, bytes)`),
  `merge!(other)` and `Klass.merge(a, b)` with protobuf merge semantics, `clear!`.
- `Klass.decode(bytes, recursion_limit: 100, frozen: false)`, `Klass.encode(message)`,
  `message.encode` (also `to_proto`), `Klass.decode_delimited(io_or_bytes)`,
  `message.encode_delimited(io = nil)`, `message.encode_to(io)`. Decoding accepts a
  String or an `IO::Buffer` and never mutates its input.

## Decoding

A reader over a String (or `IO::Buffer`) with an offset, no per-byte objects, varints via
`getbyte`, fixed-width values via `unpack1` on a `byteslice`, one `byteslice` per string
or bytes field. Rules, all of which protoc's conformance tests check:

- Every wire type, including groups (`SGROUP` and `EGROUP`) for group fields and for
  editions `DELIMITED` messages. Unknown groups are skipped correctly and kept.
- Packed and unpacked encodings are both accepted for every packable field whatever the
  descriptor says.
- A singular field appearing twice: last wins for scalars, merge for messages. Oneofs:
  last wins, siblings cleared. Maps: entries decoded as the entry message, missing key or
  value means the default, later entries overwrite.
- Enums: open enums keep unknown numbers; closed enums (proto2 and editions `CLOSED`)
  move unknown numbers to the unknown fields, including inside packed repeated fields.
- `string` fields are validated as UTF-8 when `utf8_validation?` says so, raising
  `Protostar::DecodeError`; `bytes` never are.
- Unknown fields are kept as raw bytes with their number and wire type, in order, at
  every nesting level, and re-emitted on encode after the known fields.
- Malformed input (truncated varint, length past end, unmatched group, bad wire type,
  field number 0, recursion past the limit) raises `Protostar::DecodeError` with a
  message saying what and at which byte offset.
- `frozen: true` returns a deep-frozen message in one pass without a second walk.

## Encoding

Two passes: a sizer that computes every nested length once (memoised per message
object during the pass), then a writer that emits into a String or straight to an IO
with no intermediate copy of the whole message. Fields in ascending number order, then
unknown fields verbatim. Packed encoding when `packed?`, expanded otherwise; a packed
field with no elements emits nothing. Groups and delimited messages use start and end
tags. Maps emit one entry message per pair in insertion order with key then value.
Negative int32 and enum values take ten bytes as varints. Floats via `pack("e")` and
`pack("E")`; NaN and both infinities round-trip. Required fields are not checked on
encode (google-protobuf's Ruby does not either); provide `message.initialized?` for
callers who care. Output is deterministic for the same message.

Expose `Protostar::Wire::Writer` and `Protostar::Wire::Reader` publicly with a small
documented API (write and read varint, zigzag, fixed32, fixed64, length-delimited,
tag); WS5 and WS9 build on them.

## Testing

- Wire unit tests: every varint edge (0, 1, 127, 128, 2^32-1, 2^63-1, 2^64-1, negative
  int32 and int64 as ten bytes), zigzag for sint32 and sint64 extremes, fixed32 and
  fixed64, floats and doubles including NaN, infinities, negative zero and denormals,
  tag encoding for field 1 and 536870911 and every wire type.
- Message behaviour tests on classes defined from the corpus goldens (through
  `test/support/golden_hash.rb` and `Schema::Builder`): `unittest.proto`'s `TestAllTypes`,
  `unittest_proto3.proto`, `map_unittest.proto`, `unittest_proto3_optional.proto`,
  `unittest_delimited.proto`, `edition_unittest.proto`, `unittest_mset.proto` and
  `unittest_preserve_unknown_enum.proto` cover the rules above between them.
- Property tests with `test/support/random_message.rb`: for every message in the corpus
  goldens, random instances (bounded depth, all field kinds, unknown fields injected)
  satisfy `decode(encode(m)) == m`, `encode(decode(encode(m))) == encode(m)`, and
  `to_h` round trips through `new`.
- Cross-check against the `google-protobuf` oracle gem (`skip` without
  `PROTOSTAR_ORACLE=1`): load the `.binpb` golden for a corpus file into
  `Google::Protobuf::DescriptorPool.new` via `add_serialized_file` for each file in the
  set, then for random messages assert that bytes we encode decode in the oracle to the
  same `to_h` and that bytes the oracle encodes decode in ours to the same `to_h`. Run
  this for at least the eight files above.
- Ractor tests: a class defined in the main Ractor is used to decode and encode inside
  another; a frozen message crosses the boundary; `Ractor.shareable?` holds for classes,
  enum modules and frozen messages. Guard for the Ruby 4.0 Ractor API differences.
- `DecodeError` cases with byte offsets, recursion limit, delimited stream round trips
  over a `StringIO`, `encode_to` over a pipe.

## Out of scope

JSON, text format, well-known type helpers, generated `.rb` files, the google-protobuf
facade (`RepeatedField`, `Map`, `MessageExts`, `method_missing` constants), lazy
decoding, views, `IO::Buffer` zero-copy beyond accepting it as input.
