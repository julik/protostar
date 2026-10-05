# WS5 report: JSON, text format and the well-known types

## What was built

| File | Contents |
|---|---|
| `json.rb` | `Protostar::JSON.encode(msg, **opts)`, `.decode(klass, json, **opts)` |
| `json/errors.rb` | `JSON::Error < Protostar::Error`, `JSON::ParseError` and `JSON::EncodeError`, both with `#path` |
| `json/path.rb` | the field path stack (`friends[2].name`, `labels["x"]`), turned into text only on error |
| `json/encoder.rb` | compact proto3 JSON as google-protobuf 4.36 writes it, well-known forms included |
| `json/parser.rb` | stdlib `JSON.parse` for the raw tree (never `JSON.load`), then a walk against the fields |
| `text.rb` | `Protostar::Text.print(msg, **opts)`, `.parse(klass, text, **opts)`, `Text::ParseError` (`#line`, `#column`) |
| `text/tokenizer.rb` | protoc's io::Tokenizer rules on a StringScanner |
| `text/printer.rb` | protoc's TextFormat::Printer layout, unknown fields, extensions, Any expansion |
| `text/parser.rb` | protoc's grammar and checks |
| `text/extensions.rb` | extensions read from and written to unknown fields (there is no extension API yet) |
| `well_known.rb`, `well_known/*.rb` | `WellKnown::MIXINS` and one mixin each for Any, Timestamp, Duration, Struct, Value, ListValue; `WellKnown::UnexpectedStructType` |
| `script/make_text_fixtures.rb` | runs protoc 36.2 `--encode`/`--decode` to make `test/corpus/text_format/` |
| `test/text/inputs/*.txt` | three hand-written fixture inputs (grammar corners, Any, maps) |

### API

```ruby
Klass.encode_json(msg, preserve_proto_field_names: false, emit_defaults: false, format_enums_as_integers: false, registry: nil)
Klass.decode_json(json, ignore_unknown_fields: false, registry: nil)
msg.to_json(**same)        # also accepts the gem's spelling preserve_proto_fieldnames:
Protostar::Text.print(msg, single_line: false, expand_any: true, as_utf8: false, registry: nil, pool: nil)   # also msg.to_text
Protostar::Text.parse(Klass, text, allow_unknown_fields: false, allow_partial: true, registry: nil, pool: nil)
```

`registry:` is where the type inside an Any (and the classes of extension fields) is found;
nil means `Types.registry`, looked up only when an Any or extension is met, so JSON and text
work in any Ractor for everything else. `pool:` (text only) is where extensions are found; by
default the message's file and its transitive imports are searched.

### Behaviour, as the gem has it

- Fields in declaration order (the gem's, upb's); text format in field number order (protoc's).
- Doubles: `%.15g`, or `%.17g` when 15 digits do not read back; floats `%.6g` / `%.9g` (upb's
  round-trip form, so `1e+300`, `4.94065645841247e-324`, `3.40282347e+38`, `-0`).
- Strings: only `"`, `\`, and bytes below 0x20 are escaped (`\n \r \t \f \b`, else `\u00XX`
  lower-case); U+2028, `<>&`, `/`, DEL stay raw.
- `emit_defaults`: every field without presence plus empty repeated fields and maps; fields with
  presence (messages, oneof members, proto2 and proto3 `optional`) only when set. NullValue
  fields are always `null`, even with `format_enums_as_integers`.
- Parsing: unquoted numbers go through a double for every integer kind (so `9223372036854775807`
  unquoted is out of range, `1e2` is 100); quoted integers are `-?\d+` (leading zeros allowed, no
  exponent, no spaces); quoted floats are decimal with optional leading whitespace, or
  `NaN`/`Infinity`/`-Infinity`; float overflow after rounding to single is an error; bytes accept
  both alphabets, padded or not, and refuse partial padding; `null` skips a field (it is the null
  of Value and NullValue fields); a `null` element of a repeated field or map is an error; a
  repeated key keeps the last value; an unknown enum name with `ignore_unknown_fields` leaves a
  singular field unset and drops a repeated element or map entry.
- Well-known types: Timestamp 0001..9999 with 0/3/6/9 digits, offsets accepted on input and the
  day of the month not checked (upb doesn't); Duration within ±315576000000s with matching signs;
  FieldMask refuses paths that cannot round-trip (upper case, `_` not before a lower-case letter)
  and `_` on input; Value refuses NaN/Infinity and an unset kind; Any needs a `/` with something
  before it, and Empty inside Any is an ordinary message (`{"@type": ...}`, no `"value"`), like
  upb, which gives Empty no special form.

## Tests

221 runs are WS5's (779 in the suite). `bundle exec rake` is clean (tests and standard): 779 runs,
0 failures, 121 skips (the 109 WS3 oracle tests, 10 WS5 oracle tests, 2 of WS1). Green on Ruby 3.4.1,
3.2.2 and 4.0.0. With `BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`: 779 runs, 58905 assertions,
0 failures, 0 skips on 3.4.1, and the same on 4.0.0.

| File | Runs | Covers |
|---|---|---|
| `test/json/encode_test.rb` | 9 | names and `json_name`s, both option spellings, every scalar kind, float forms, escapes, base64, enums and aliases, maps, oneofs, `emit_defaults` with proto3 optional, unknown fields dropped, the conveniences, stdlib `JSON.generate` calling `to_json` |
| `test/json/decode_test.rb` | 11 | every accepted and refused integer, float, bool, string and bytes form, enums with and without `ignore_unknown_fields`, null rules, oneofs, maps, error paths, malformed JSON |
| `test/json/well_known_test.rb` | 9 | Timestamp, Duration, FieldMask, Struct/Value/ListValue, wrappers, Empty, Any (regular, nested, well-known inside, non-googleapis prefix, errors, another registry) |
| `test/json/oracle_test.rb` | 10 | see below |
| `test/json/ractor_test.rb` | 1 | `to_json`, `to_text`, `decode_json`, `Text.parse` inside another Ractor on a frozen message |
| `test/text/fixtures_test.rb` | 35 | the protoc fixtures (below) |
| `test/text/round_trip_test.rb` | 107 | every message of every golden's own file, 3 random instances, printed both multi-line and single-line and parsed back equal |
| `test/text/parser_test.rb` | 16 | integers in every base and range, floats, booleans, string escapes and concatenation, enums, braces, lists, separators, group names, comments, maps, oneof and repeated-singular refusals, `line:col` errors, unknown-field skipping, extensions (packed too), Any expansion, `allow_partial` |
| `test/text/printer_test.rb` | 9 | exact layout, single line, scalars, CEscape and `as_utf8`, unknown fields of every wire type, extensions by name and with an empty `pool:`, Any expanded and not, sorted maps, delimited fields that are and are not group-like |
| `test/well_known/*_test.rb` | 14 | every helper; Timestamp nanoseconds, zones and pre-epoch times; Any with the registry, custom prefixes, the process-wide registry; Struct with nested lists and nulls; ListValue as Enumerable |

### Text fixtures

`script/make_text_fixtures.rb` feeds protoc 36.2 the six corpus `testdata/text_format_*.txt`,
`testdata/map_test_data.txt` and `test/text/inputs/{grammar,any,maps}.txt`. For each it writes
`.binpb` (`--encode`), `.txt` (`--decode`), `.unknown.txt` (the same bytes decoded as
`proto2_unittest.TestEmptyMessage`, all fields unknown), or `.error.txt` when protoc rejects the
input. Two corpus files are rejected by protoc (`text_format_unittest_data.txt` and `_pointy.txt`
set three members of one oneof); the tests assert that we reject them with the same reason. For
the other eight: our parse of the source gives protoc's bytes exactly, our print of the bytes
gives protoc's text exactly (with `expand_any: false`, since `--decode` does not expand), our print
as TestEmptyMessage gives protoc's unknown-field text exactly, and parsing protoc's text back
gives an equal message with equal unknown fields. The two extension fixtures go through
`[ext.name]` in both directions.

### Oracle JSON cross-check

`test/json/oracle_test.rb`, for unittest_proto3, test_messages_proto3, map_unittest,
unittest_proto3_optional and the duration, timestamp, struct, wrappers, field_mask and empty goldens:
every message, 6 random instances (`RandomMessage` plus `test/support/well_known_random.rb`, which
gives well-known types valid contents and packs real messages into Any with several prefixes),
under all 8 option combinations. Each time: our `encode_json` equals the gem's; the gem's JSON
decodes in ours to an equal message; ours decodes in the gem to an equal message.

At the default 6 instances: 282 messages, 2256 comparisons, 1920 byte-identical, 336 identical
except for map entry order (upb iterates maps in hash order); for those the parsed trees are
equal and every number and string token is spelled the same. Run with
`PROTOSTAR_ORACLE_INSTANCES=20` as well: no differences. Nothing in the encoder or parser was
left differing from the gem on what the cross-check generates.

## Deviations from the spec, and why

1. **Text strings are escaped like protoc by default.** The spec asks for "CEscape with UTF-8 kept
   readable", but `protoc --decode` escapes every byte above 0x7E in octal, and the fixtures are its
   output. `as_utf8: true` keeps valid UTF-8 readable (protoc's `Utf8FieldValuePrinter`).
2. **Any expansion is an option.** `expand_any: true` is the default, as the spec says, but protoc
   `--decode` never expands, so the fixture tests pass `expand_any: false`. We expand any prefix
   when the type is in the registry and the bytes decode; protoc's default finder only knows
   `type.googleapis.com/` and `type.googleprod.com/`.
3. **Extensions are handled although out of scope**: two of the six corpus fixtures are made of
   `[ext.name]` fields. Parsed extensions become the unknown fields the binary codec would have
   kept (in number order, packed when the extension is), and the printer names unknown fields that
   match an extension. No extension API was added to Message.
4. **`preserve_proto_field_names`** (the spec's name) and **`preserve_proto_fieldnames`** (the
   gem's) are both accepted.
5. **Encoding errors raise `JSON::EncodeError`**; the gem raises its ParseError for those too.
6. **JSON errors carry the field path, not `line:col`.** The stdlib parser does not report positions
   of values.
7. **`map_test_data.txt` and three hand-written inputs** are fixtures beyond the six
   `text_format_*.txt` the spec names.

## Where we differ from google-protobuf's Ruby gem (all edge cases)

- The gem refuses to `decode_json` a wrapper type at the top level ("Cannot parse a wrapper
  directly"); we parse it (`Int32Value.decode_json("7")`).
- The gem accepts the quoted integer `"-"` as 0; we refuse it. The gem's quoted floats go through
  `strtod`, so `"inf"` and `"0x10"` parse; we take decimals and `NaN`/`Infinity`/`-Infinity` only.
- The stdlib parser collapses duplicate keys to the last value before we see them, so
  `{"oneofUint32": 1, "oneofUint32": 2}` is accepted (the gem reports two oneof members). Two
  different members of a oneof are refused as in the gem.
- A proto2 string holding invalid UTF-8 is written with U+FFFD replacements; the gem writes the raw
  bytes, which is not valid JSON text either.
- `-0` in JSON input is rewritten to `-0.0` before parsing (only when the input contains `-0`),
  because the stdlib reads it as the Integer 0 and the sign of a double field would be lost.
- The gem keeps unknown numbers of closed enums; JSON parsing here refuses them (or drops them with
  `ignore_unknown_fields`), as WS3 does on the wire.

## Changes to WS3 files

- `lib/protostar/message.rb`: `to_h` became `__to_h` (recursing through `__to_h`) with `to_h`
  calling it. The Struct mixin replaces `to_h` with google-protobuf's plain-Hash form, and nested
  Structs must still convert field by field, as in the gem. Added `to_json`, `to_text`,
  `Klass.encode_json`, `Klass.decode_json`, each a one-line delegation.
- `lib/protostar/types.rb`: two lines at the end of `Definer#setup` include
  `WellKnown::MIXINS[full_name]` when there is one. The frozen table lives in `well_known.rb`.
- `lib/protostar/message/coercion.rb`: `Coercion.float32`. Ruby's `pack("e")` turns every double
  above FLT_MAX into Infinity, even those that round down to FLT_MAX in C (`3.40282347e+38`, the
  JSON form of FLT_MAX). Assigning such a value to a float field gave Infinity. Now it gives
  FLT_MAX; JSON and text parsing use the same function.
- `lib/protostar.rb`: requires `well_known`, `json`, `text`.
- `test/support/random_message.rb`: sets fields with `__set` instead of `msg[name] =`, because
  Struct and ListValue replace `[]=` (as in the gem).
- `test/codec/property_test.rb`, `test/codec/oracle_test.rb`: compare `__to_h` instead of `to_h`,
  for the same reason.

## Found along the way

- **Float NaN payloads and signs do not survive the wire** (WS3): `Wire::Writer#write_float` uses
  `pack("e")`, which Ruby canonicalises to 0x7fc00000 for any NaN. A negative or payload-carrying
  float NaN decodes and re-encodes differently. Doubles keep their bits. The grammar fixture puts
  `-nan` in a double field for that reason.
- **protoc `--decode` keeps duplicate map keys** (DynamicMessage stores map entries as a repeated
  field), printing both. Maps here are Hashes and keep the last; the maps fixture avoids repeated keys.
- protoc accepts invalid UTF-8 in a proto2 `string` in text format; here the WS3 coercion refuses
  it for every string field, so the text parser reports "string is not valid UTF-8".

## For the next workstreams

- **WS4 (generated code)**: WellKnown mixins arrive through `Types.define`, so a bootstrap that
  defines the well-known files gets the helpers without extra calls. The JSON and text code only
  needs `Klass.descriptor`, `__fields`, `__by_name`, `__by_number`, `__values`, `__set`.
- **WS6 (shim)**: the helper names are google-protobuf's (`Any.pack`, `#unpack`, `#is`, `#type_name`,
  `Timestamp.from_time`, `#to_time`, `#to_i`, `#to_f` returning a Rational as the gem does,
  `Duration#to_f`, `Struct.from_hash`, `#to_h`, `#[]`, `#[]=`, `#has_key?`, `Value.from_ruby`,
  `#to_ruby(recursive)`, `ListValue.from_a`, `#to_a`, `#length`, `#[]`, `#[]=`, `#<<`, `#each`,
  Enumerable). The gem's `Value#kind` is our `which_kind`; the gem's `encode_json(msg, options_hash)`
  takes a positional Hash where ours takes keywords; map `JSON::ParseError`/`EncodeError` and
  `WellKnown::UnexpectedStructType` to the gem's classes; the gem's `to_json(options = {})` matches
  ours when called with keywords. `Message#to_h` of a Struct is the plain Hash, as in the gem.
- **WS7 (conformance)**: JSON in and out is `Klass.decode_json(json, ignore_unknown_fields:)` and
  `Klass.encode_json(msg, preserve_proto_field_names:)`; text is `Protostar::Text.parse(Klass, text)`
  and `Protostar::Text.print(msg)` (the conformance suite's text expectations may want
  `as_utf8: true`). Pass the testee's registry as `registry:` so Any resolves. Expected failure areas,
  where the gem itself departs from the spec: `-`/`inf`/hex quoted numbers (above), the 64-bit
  integers that go through a double, the day-of-month and leap-second leniency in Timestamp,
  duplicate keys, top-level wrappers.

## Open questions

1. Should the gem's JSON leniencies (quoted `"inf"`, hex floats, `"-"` as 0) be copied for the shim,
   or should we keep the stricter reading and let the conformance list decide?
2. Is `expand_any: true` the right default for `Text.print`, given that `protoc --decode` does not
   expand? `to_text` inherits it.
3. Should WS3 coerce invalid UTF-8 in proto2 `string` fields leniently (protoc does), which would
   let text and JSON accept it too?
4. Who owns extensions (WS3's open question 1)? The text format now reads and writes them through
   unknown fields; a real extension API would replace `Text::Extensions`.
5. Should `Wire::Writer#write_float` keep NaN bits (pack the bits of a double-to-single conversion
   by hand) so float NaN payloads round-trip like doubles?
