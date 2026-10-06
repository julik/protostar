# Clean Marshal and JSON round trips, for Rails caching and friends

**Status:** feature lead from Julik, 2026-10-06. Not scheduled, but should go before 0.1.0 is
widely used: `Rails.cache` and `ActiveJob` arguments go through `Marshal` (or Rails' JSON
serializer), and today's behaviour is accidental.

## What happens today (measured on main, 2026-10-06)

| Case | Result |
| --- | --- |
| `Marshal.dump(message)` on a generated class | works, by dumping instance variables: 76 bytes for a message whose wire form is 7 bytes; the format is the internal slot layout, so a cache entry written by one protostar version may not load in the next |
| `Marshal.load` of that | equal to the original; a frozen message comes back unfrozen |
| `Marshal.dump(view)` | 16 bytes, and `Marshal.load` raises `TypeError: incompatible marshal file format` |
| Anonymous classes from `Types.define` without a namespace | `can't dump anonymous class` |
| Shim messages | would also dump the memoised `RepeatedField` and `Map` wrappers and the shim's extra state |
| `message.to_json`, `JSON.generate(message)` | proto3 JSON, round-trips through `decode_json` |
| `as_json` | not defined. Under ActiveSupport, `to_json` is routed through `as_json`, and `Object#as_json` serialises instance variables, so inside Rails `message.to_json` would produce the slot layout, not protobuf JSON. `render json: message` has the same problem |

## What it should be

**Marshal** carries the wire bytes, nothing else:

- `marshal_dump` returns the encoded message (plus a small version tag), `marshal_load`
  decodes it. Compact, independent of the storage model, and the same bytes any protobuf
  reader understands. Unknown fields survive because the codec keeps them.
- Frozen in, frozen out: a frozen message dumps a flag and loads frozen (shareable again).
- Views dump as their bytes and load as a view over the loaded String (frozen), so a view
  cached once is still zero-copy on the way back; `to_message` is the caller's choice.
- Shim messages dump the same way, through the same two methods, and load into the shim's
  class; the wrappers are rebuilt lazily as today.
- `RepeatedField` and `Map` in the shim dump as plain Arrays and Hashes of their contents
  (the C gem's behaviour to check and match).
- Anonymous classes: a message whose class has no name cannot be marshalled by design;
  raise a clear `Protostar::Error` naming the fix (`Types.define(file, name:)` or a
  constant assignment) instead of Ruby's generic `TypeError`.
- Enum values are Symbols and Integers already; nothing to do.

**JSON** means protobuf JSON everywhere Rails looks:

- `as_json(options = nil)` returns the proto3 JSON *tree* (the Hash `JSON.parse` of
  `to_json` would give), honouring the same keywords as `encode_json`
  (`emit_defaults`, `preserve_proto_field_names`, `format_enums_as_integers`), so
  `render json:`, `ActiveSupport::JSON.encode`, `to_json` under ActiveSupport and
  `ActiveModel::Serializers` all produce the mapping.
- `to_json` keeps accepting a `JSON::State` (WS13) and ignores ActiveSupport's options
  Hash it does not know.
- `Klass.from_json` / `decode_json` accept the tree as well as the String, so
  `Klass.decode_json(JSON.parse(s))` and ActiveJob's JSON-serialised arguments round-trip.
- `ActiveJob` arguments: register a `ActiveJob::Serializers::ObjectSerializer` subclass for
  `Protostar::Message` in a Railtie-free way (a `protostar/active_job` file the app
  requires) that serialises to `{klass: full_name, bytes: base64}` and resolves the class
  through `Types.registry`, so jobs can take messages directly.
- `Rails.cache` with the `:json` serializer (Rails 7.1+) goes through `as_json`; with the
  default `Marshal` coder it goes through `marshal_dump`. Both covered above.

## Tests

- Marshal round trips for every message type in the corpus goldens with random messages
  (`test/support/random_message.rb`): `Marshal.load(Marshal.dump(m)) == m`, byte size of
  the dump within a few bytes of `m.encode.bytesize`, frozen state preserved, views load
  as views, unknown fields intact; shim messages likewise through `rake shim:test`.
- A dump made by the previous protostar version loads (a committed fixture, regenerated
  only on a deliberate format change).
- `as_json` equality with `JSON.parse(to_json)` for every option combination, and under a
  loaded `active_support/json` (dev dependency, test only): `message.to_json`,
  `ActiveSupport::JSON.encode(message)` and `[message].to_json` give the mapping.
- An ActiveJob serializer test with a real `ActiveJob::Base` in the test process.
- Anonymous-class error message.

## Effort

Small for Marshal and `as_json` (two methods each on `Message`, `View` and the shim's
message module, plus the error). Small-to-medium for the ActiveJob serializer and the
ActiveSupport tests, which add development dependencies on `activesupport` and
`activejob` (test group only).
