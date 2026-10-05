# WS1: the descriptor model (`Protostar::Schema`)

Everything in protostar hangs off this: the compiler produces it, generated code
rebuilds it at require time, the codec reads it to encode and decode, and the
google-protobuf shim wraps it. Build it so that each of those can be written against it
without talking to you.

## Deliverables

Files under `lib/protostar/schema/` plus `lib/protostar/schema.rb` requiring them, tests
under `test/schema/`, and `test/support/golden_hash.rb` (see Testing).

## The lingua franca: the descriptor hash

The input to this model, and the output of `#to_h`, is a plain Ruby Hash shaped exactly
like `FileDescriptorProto#to_h` from the google-protobuf gem:

- Symbol keys named after the proto fields of `descriptor.proto`: `:name, :package,
  :dependency, :public_dependency, :weak_dependency, :message_type, :enum_type, :service,
  :extension, :options, :source_code_info, :syntax, :edition`, and so on recursively
  (`DescriptorProto` has `:field, :nested_type, :enum_type, :extension_range, :extension,
  :options, :oneof_decl, :reserved_range, :reserved_name`; `FieldDescriptorProto` has
  `:name, :number, :label, :type, :type_name, :extendee, :default_value, :oneof_index,
  :json_name, :options, :proto3_optional`). Read `test/corpus/protobuf/src/google/protobuf/descriptor.proto`
  for the full shape; it is the spec.
- Enum-typed fields hold Symbols spelled as the proto enum value: `:LABEL_OPTIONAL`,
  `:TYPE_INT32`, `:EDITION_2023`, `:SPEED`, `:EXPLICIT`.
- Absent fields are absent keys. Repeated fields are Arrays (possibly empty or absent).
  int64 values are Integers. `bytes` values are binary Strings.
- `type_name` and `extendee` are fully qualified with a leading dot, as protoc emits them
  (`.protobuf_unittest.TestAllTypes.NestedMessage`). Accept names without a leading dot
  too and resolve them with the scoping rules below; protoc allows that in a
  `FileDescriptorProto`.
- Options are the option message as a hash of its known fields (`{java_package: "x",
  deprecated: true, features: {field_presence: :EXPLICIT}}`), plus two keys of our own:
  `:__extensions`, a Hash from an extension's full name (no leading dot) to its Ruby
  value (nested hashes for message-typed options), and `:__unknown_fields`, an Array of
  `[field_number, wire_type, raw_bytes]` triples for option bytes nobody could interpret.
  Both are optional and both must round-trip through `to_h`.

`Schema::Builder.build(hash, pool:)` turns such a hash into a linked, frozen
`Schema::File`. `Schema::File#to_h` turns it back. For every protoc-produced hash,
`build(h).to_h == h` after the normalisation that `json_name` and `source_code_info`
imply (see Testing).

## Classes

All descriptors are plain classes with `attr_reader`s, built by the Builder, deep-frozen
at the end of construction and passed through `Ractor.make_shareable`. They reference
each other directly (a field holds its message type), never a Pool. Collections are
frozen Arrays and Hashes. Strings are frozen. Nothing in a built descriptor is mutable.

`name` is the simple name. `full_name` is fully qualified without a leading dot. Enum
values take their `full_name` in the enum's *enclosing* scope, as protoc does (value
`FOO` of `pkg.Color` is `pkg.FOO`), and that is also the scope they clash in.

**`Schema::File`**: `name`, `package` (String, `""` when none), `syntax` (`:proto2`,
`:proto3` or `:editions`), `edition` (Symbol or nil), `dependencies` (file names),
`public_dependencies`, `weak_dependencies`, `dependency_files` (linked `File`s),
`messages`, `enums`, `services`, `extensions` (top level), `options`, `features`,
`source_info` (or nil), `all_messages` (recursive, declaration order), `all_enums`,
`all_extensions`, `find_message(full_name)`, `find_enum`, `find_symbol`, `to_h`.

**`Schema::Message`**: `name`, `full_name`, `file`, `containing_message`, `index`,
`fields` (declaration order, including oneof members, excluding extensions),
`fields_by_number`, `fields_by_name`, `fields_by_json_name`, `field(number_or_name)`,
`oneofs`, `real_oneofs` (not synthetic), `nested_messages`, `nested_enums`, `extensions`
(declared in this scope), `extension_ranges` (Array of inclusive Ranges),
`reserved_ranges`, `reserved_names`, `options`, `features`, `map_entry?`,
`message_set_wire_format?`, `to_h`.

**`Schema::Field`**: `name`, `full_name`, `number`, `label` (`:optional`, `:required`,
`:repeated`), `type` (`:double :float :int64 :uint64 :int32 :fixed64 :fixed32 :bool
:string :group :message :bytes :uint32 :enum :sfixed32 :sfixed64 :sint32 :sint64`),
`type_name` (full name without dot, nil for scalars), `message_type`, `enum_type`,
`default_value` (declared default parsed to a Ruby value, or nil), `default` (declared
default or the type's implicit default, so never nil for scalars; the first enum value
for enums; nil for messages), `json_name`, `oneof`, `proto3_optional?`, `extension?`,
`extendee`, `containing_message` (the message that holds the field, or for an extension
the scope it was declared in or nil), `file`, `index`, `options`, `features`. Derived:
`repeated?`, `required?`, `optional?`, `map?`, `scalar?`, `packed?` (resolved: proto2
defaults unpacked, proto3 packs packable scalars, editions follow
`repeated_field_encoding`, and an explicit `packed` option wins where the syntax allows
it), `packable?`, `presence?` (explicit presence: proto2 singular fields, proto3
`optional` and message-typed and oneof members, editions `field_presence` not
`IMPLICIT`), `delimited?` (groups, and editions `message_encoding: DELIMITED`),
`wire_type` (0, 1, 2, 3 or 5 for one unpacked value), `utf8_validation?`.

**`Schema::Oneof`**: `name`, `full_name`, `containing_message`, `index`, `fields`,
`synthetic?`, `options`, `features`.

**`Schema::Enum`**: `name`, `full_name`, `file`, `containing_message`, `index`, `values`
(declaration order), `values_by_number` (first declared wins for aliases),
`values_by_name`, `value(number_or_name)`, `allow_alias?`, `closed?` (proto2 true,
proto3 false, editions by `enum_type`), `reserved_ranges`, `reserved_names`, `options`,
`features`, `to_h`.

**`Schema::EnumValue`**: `name`, `full_name`, `number`, `enum`, `index`, `options`,
`features`.

**`Schema::Service`** and **`Schema::Method`**: `name`, `full_name`, `file`/`service`,
`index`, `methods`/`method(name)`, `input_type`, `output_type`, `client_streaming?`,
`server_streaming?`, `options`, `features`, `to_h`.

**`Schema::Options`**: an immutable wrapper over the options hash. `[](key)`, `fetch`,
`key?`, `to_h`, `extensions` (the `:__extensions` Hash, `{}` if none), `unknown_fields`
(the `:__unknown_fields` Array, `[]` if none), `empty?`, `features` (the raw `:features`
hash, if any). `Options::EMPTY` for descriptors that declared none.

**`Schema::Features`**: resolved editions features as a frozen value object: `field_presence`,
`enum_type`, `repeated_field_encoding`, `utf8_validation`, `message_encoding`,
`json_format`, `enforce_naming_style`, `default_symbol_value`, plus `to_h`. proto2 and
proto3 are modelled as editions `EDITION_PROTO2` and `EDITION_PROTO3` with their fixed
defaults, the way protoc does internally. Defaults for `EDITION_PROTO2`,
`EDITION_PROTO3`, `EDITION_2023` and `EDITION_2024` come from the `edition_defaults`
annotations in `descriptor.proto`; transcribe them, cite the line, and test that the
transcription matches what the annotations say. Resolution inherits file to message
(through nested messages) to oneof to field, file to enum to value, message to extension
range, file to service to method, with the element's own `features` option overriding.
Legacy proto2 and proto3 spellings map onto features: `required` is
`LEGACY_REQUIRED` presence, `packed = true/false` is the repeated encoding, `group` is
`DELIMITED`, proto3 `optional` is `EXPLICIT`.

**`Schema::SourceInfo`** with `locations` (Array of `Location`: `path`, `span`,
`leading_comments`, `trailing_comments`, `leading_detached_comments`) and
`location(path)`. Stored verbatim from the hash and reproduced by `to_h`.

**`Schema::Pool`**: a mutable, Mutex-guarded registry of built files. `add(file)` raises
`Schema::Error` on a duplicate file name or a symbol already defined; `file(name)`,
`files`, `find_message(full_name)`, `find_enum`, `find_service`, `find_symbol`,
`find_extension(extendee_full_name, number)`, `extensions_of(message)`, `include?(file_name)`.
The Pool is not shareable; what it holds is.

**`Schema::Resolver`**: protoc's C++-style scoped name lookup, public so the compiler's
linker reuses it. `Resolver.resolve(name, scope:, file:, pool:)` where `scope` is the full
name of the enclosing message or package: a name with a leading dot is looked up as is;
otherwise look the *first component* up from the innermost scope outward, and once that
component is found, the rest must resolve beneath it or the lookup fails without
searching further out (this is the rule protoc documents in `descriptor.proto` under
`type_name`). Dependencies are visible only through direct imports and transitively
through `public` imports. Return the descriptor or raise `Schema::ResolveError` with the
name and scope in the message.

**`Schema::Builder`**: `build(hash, pool:)`. Constructs the graph, resolves every
`type_name` and `extendee` with the Resolver, computes `json_name` where the hash lacks
it (protoc's rule: drop underscores, upper-case the letter after each), parses
`default_value` strings per type (integers, floats including `inf`, `-inf` and `nan`,
booleans, enum names to Symbols, strings as given, bytes by unescaping protoc's C-escaped
form), resolves features, links dependencies from the pool (raising if a dependency is
missing), freezes everything and returns the `File`. It does not validate what the
compiler validates: duplicate numbers, reserved clashes and the like are the compiler's
job. It does raise on dangling references and malformed hashes. Building does not add
the file to the pool; the caller does.

## Testing

- Write `test/support/golden_hash.rb`: converts a golden `.json` (protoc's JSON mapping of
  a `FileDescriptorSet`) into an Array of descriptor hashes as defined above (lowerCamel
  JSON names back to proto field names, enum strings to Symbols, int64 strings to
  Integers, base64 bytes to binary Strings). This helper is reused by later workstreams,
  so make it correct and small.
- For every golden `.json` in the corpus: convert, build the files in dependency order
  into a fresh Pool, and assert `file.to_h == hash` for each. Assert
  `Ractor.shareable?(file)`.
- Targeted assertions on `unittest.proto`, `unittest_proto3.proto`, `map_unittest.proto`,
  `unittest_custom_options.proto`, `edition_unittest.proto`, `unittest_delimited.proto`
  and `unittest_proto3_optional.proto`: field numbers, types, labels, defaults (including
  the bytes and float specials in `unittest.proto`), json names, oneofs and synthetic
  oneofs, map detection, packedness across proto2, proto3 and editions, presence,
  delimited encoding, open versus closed enums, extension lookup by extendee and number,
  nested scoping, enum value full names.
- Resolver tests covering the scoping rules, written from the `type_name` comment in
  `descriptor.proto` and the lookup tests in
  `test/corpus/protobuf/src/google/protobuf/descriptor_unittest.cc`.
- Features defaults and inheritance tests.
- Pool: duplicate detection, lookups, concurrent `add` from several threads.
- A Ractor test that builds in the main Ractor and reads descriptors inside another.

## Out of scope

Parsing `.proto` text, binary encoding or decoding, generated message classes, the
google-protobuf facade. If you need to read a `.binpb` golden, you cannot yet; use the
`.json` ones.
