# WS5: JSON, text format and the well-known types

Three things that sit on top of the codec and the descriptors: the proto3 JSON mapping in
both directions, protoc's text format as a printer and a parser, and the Ruby helpers
for the well-known types. Read `ws3-codec.md` and `llm/outputs/ws3-report.md` first for
what the Message runtime gives you (`descriptor`, `Klass.__fields`, `msg[name]`,
`Types.define`, `Types.find`, `Wire::Reader` and `Writer`), and `ws1-descriptor-model.md`
for the descriptors.

## Deliverables

`lib/protostar/json.rb` with `lib/protostar/json/` (encoder, parser, errors),
`lib/protostar/text.rb` with `lib/protostar/text/` (printer, parser, tokenizer),
`lib/protostar/well_known.rb` with `lib/protostar/well_known/` (one mixin per type), tests
under `test/json/`, `test/text/`, `test/well_known/`, and any protoc-made fixtures under
`test/corpus/text_format/` with the script that made them in `script/`.

## JSON

The proto3 JSON mapping as the protobuf docs specify it and as google-protobuf's Ruby
implements it. The oracle gem is your reference: for any message its `encode_json` and
`decode_json` define the expected output and the accepted input, and the conformance
suite (WS7) will later check the corners.

API, mirroring the codec's shape:

```ruby
Klass.decode_json(string, ignore_unknown_fields: false)
Klass.encode_json(msg, preserve_proto_field_names: false, emit_defaults: false, format_enums_as_integers: false)
msg.to_json(**same)                      # also Protostar::JSON.encode / .decode
```

Rules to implement, all of them:

- Field names: `json_name` on output, both `json_name` and the original name accepted on
  input. `preserve_proto_field_names` emits the original.
- `int32`, `uint32`, `sint32`, `fixed32`, `sfixed32` as JSON numbers; the 64-bit kinds as
  decimal strings. On input every integer kind accepts a number or a numeric string,
  rejects fractions that are not exactly integral (`1.0` is fine, `1.5` is not) and
  out-of-range values. Floats and doubles as numbers, with `"NaN"`, `"Infinity"`,
  `"-Infinity"` as strings; on input accept numbers and numeric strings. `bool` strict.
  `string` as is. `bytes` as standard base64 with padding on output; on input accept
  standard and URL-safe alphabets with or without padding.
- Enums as the value name, or the number when the number has no name or
  `format_enums_as_integers` is set. On input accept names and numbers; an unknown name
  is an error unless `ignore_unknown_fields`; `null` means the default.
- Messages as objects, repeated fields as arrays, maps as objects with string keys
  (integer and bool keys converted both ways). Oneofs emit only the set member; two set
  members on input is an error. `null` for a message field clears it, except for
  `Value`, where it is `NullValue`.
- `emit_defaults` emits every field with its default, including empty arrays and maps,
  but never unset message fields or unset oneof members, as the Ruby gem does.
- Unknown fields on input raise `Protostar::JSON::ParseError` unless
  `ignore_unknown_fields`. Unknown wire fields on the message are never emitted.
- Well-known types take their special forms: `Timestamp` as RFC 3339 UTC with `Z` and
  0, 3, 6 or 9 fractional digits; `Duration` as `"1.500s"` style with the same digit
  rule; `Any` as `{"@type": url, ...fields}` or `{"@type": url, "value": ...}` for a
  well-known inner type, resolved through `Types.find` and the registry; `Struct`,
  `Value`, `ListValue` as plain JSON; the wrappers as their primitive; `FieldMask` as a
  comma-joined lowerCamel string; `Empty` as `{}`; `NullValue` as `null`.
- Parsing uses the stdlib `json` for the raw tree (it is a default gem, allowed) and never
  `JSON.load`. Errors carry the field path (`person.friends[2].name`).

## Text format

protoc's text format, the one `protoc --decode` prints and `--encode` reads, used by the
`.textproto` fixtures in the corpus and by the conformance text-format suite.

```ruby
Protostar::Text.print(msg, single_line: false)   # also msg.to_text
Protostar::Text.parse(Klass, string, allow_unknown_fields: false, allow_partial: true)
```

Printer: protoc's layout exactly (two-space indent, `name: value`, `name {` blocks,
repeated fields one per line, strings escaped as protoc's `CEscape` does with UTF-8 kept
readable, floats in protoc's shortest round-trip form, enums by name, unknown fields as
`number: value` and `number { }` groups the way protoc prints them, `Any` expanded as
`[type.googleapis.com/full.Name] { }` when the type is known). Parser: the full grammar
including `key: value` and `key { }` and `key < >`, repeated short form `[1, 2]`,
`[ext.name]` extension and `[type.url/Name]` Any forms, string literal concatenation and
every escape, enum names and numbers, hex and octal integers, `inf`, `-inf`, `nan`,
`true`/`false`/`t`/`f`/`1`/`0` booleans, comments, and errors as `line:col: message`.

Fixtures: write `script/make_text_fixtures.rb` that uses protoc 36.2
(`~/.cache/protostar/protoc-36.2/bin/protoc --encode` and `--decode` with the corpus
include roots) to turn every `test/corpus/protobuf/src/google/protobuf/testdata/text_format_*.txt`
into its binary form and its canonical re-printed text, committed under
`test/corpus/text_format/`. Tests then assert parse(text) == binary and
print(decode(binary)) == canonical text without protoc present.

## Well-known types

A mixin per type under `Protostar::WellKnown`, applied by `Types.define` when it defines a
class whose full name matches (add the hook in `Types` with a frozen table; keep the
change to `lib/protostar/types.rb` minimal and note it in the report). The classes
themselves will be defined by WS4's generated bootstrap; in your tests define them from
the corpus goldens for `any`, `duration`, `timestamp`, `struct`, `wrappers`,
`field_mask` and `empty`.

Helpers, matching google-protobuf's `well_known_types.rb` so the shim can alias them:
`Any.pack(msg, type_url_prefix)`, `Any#pack`, `Any#unpack(klass)`, `Any#type_name`,
`Any#is(klass)`; `Timestamp.from_time`, `Timestamp#to_time`, `#to_i`, `#to_f`,
`Timestamp#from_time`; `Duration#to_f`; `Struct#to_h`, `Struct.from_hash`, `Struct#[]`,
`[]=`, `has_key?`, `Value#to_ruby`, `Value.from_ruby`, `ListValue#to_a`,
`ListValue.from_a`, `[]`, `<<`, `each`, `Enumerable`. Keep the native names identical to
Google's where they exist and add nothing that forces a dependency on the shim.

## Testing

- JSON: hand-written cases per rule above on classes defined from the corpus goldens for
  `unittest_proto3.proto`, `test_messages_proto3.proto`, `map_unittest.proto` and the
  well-known types, with the exact strings asserted. Then the oracle cross-check
  (`skip` without `PROTOSTAR_ORACLE=1`): for random messages from
  `test/support/random_message.rb` across those files, our `encode_json` equals the
  oracle's for every option combination, and the oracle's JSON parses in ours to an
  equal message and vice versa. Error cases with their paths.
- Text: the protoc fixtures above, printer and parser round trips over random messages,
  error cases, unknown field printing.
- Well-known: each helper, including `Timestamp` nanosecond handling and `Time` zones,
  `Any` with the registry and a type URL prefix that is not `type.googleapis.com`,
  `Struct` with nested lists and nulls.

## Out of scope

The google-protobuf facade, generated files, the conformance testee (WS7 wires your
code into it), extensions.
