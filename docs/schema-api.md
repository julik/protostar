# The Schema API

`Protostar::Schema` objects (`File`, `Message`, `Field`, `Oneof`, `Enum`, `EnumValue`,
`Service`, `Method`, `ExtensionRange`) are protostar's one representation of a `.proto` file.
They are built directly, read directly, frozen and Ractor-shareable. protoc's shape, the
`FileDescriptorProto`, exists only at the edges, as a translation:

| Edge | API | Used by |
|---|---|---|
| in | `Schema::File.from_proto(message_or_bytes, pool:)`, `Pool#add_serialized_file`, `Protostar.load_descriptor_set` | the shim, the protoc plugin, tests reading `.binpb` goldens |
| out | `File#to_proto`, `File#serialize`, `#to_proto` on every descriptor and on `Options` | descriptor sets, the Google-format emitter, the shim's `to_proto` |
| compare | `to_proto.to_h` against the golden JSON read into the same message classes | tier A, the round-trip tests |

Nothing in protostar passes a `FileDescriptorProto`-shaped Hash from one stage to the next.
`to_h` survives on descriptors as `to_proto.to_h`, a projection for reading.

This document shows the three APIs that replaced the hashes: drafting, options and
reflection. Every output below was produced by running the code (Ruby 3.4.1).

## Drafting a file

```ruby
pool = Protostar::Schema::Pool.new
file = Protostar::Schema::File.draft("shop.proto", package: "shop", syntax: :proto3)
item = file.message("Item") do |m|
  m.field "name", 1, :string
  m.field "price_cents", 2, :int64, optional: true
  m.map "stock", 3, key: :string, value: :int32
end
item                     # => #<Protostar::Schema::Draft::Message shop.Item>
item.descriptor          # => #<Protostar::Schema::Message shop.Item>
built = file.resolve(pool).freeze!
built                    # => #<Protostar::Schema::File shop.proto>
built.equal?(file.descriptor)                              # => true
Ractor.shareable?(built)                                   # => true
built.find_message("shop.Item").oneofs.map { |o| [o.name, o.synthetic?] }          # => [["_price_cents", true]]
built.find_message("shop.Item").nested_messages.map { |n| [n.name, n.map_entry?] } # => [["StockEntry", true]]
```

The calls speak Ruby: types are `:int32`, `:string`, `:message`, `:enum`, `:group`, or a
type name as a String whose kind is found when linking; labels are `:optional`,
`:required`, `:repeated`; syntax is `:proto2`, `:proto3` or `:editions`, editions are
`:EDITION_2023` and so on. What the draft offers:

| Scope | Calls |
|---|---|
| file | `message`, `enum`, `service`, `extend(extendee) { \|e\| e.field ... }`, `extension(..., extendee:)`, `source_info=`, `set_options(descriptor, options)` |
| message | `field(name, number, type, type_name = nil, label:, default:, json_name:, optional:, oneof:, options:)`, `map(name, number, key:, value:)`, `group(name, number) { \|g\| }`, `oneof(name) { \|o\| }`, `extensions(*ranges)`, `extension_range(range)`, `reserved(*numbers_ranges_and_names)`, `message`, `enum`, `extend` |
| enum | `value(name, number, options:)`, `reserved` |
| service | `rpc(name, input, output, client_streaming:, server_streaming:, options:)` |

### What the draft makes

protoc's descriptors contain things nobody wrote. The draft makes them, by the rules
protoc's parser uses:

- `map` adds the entry message (`StockEntry`: the field name in CamelCase plus `Entry`,
  `map_entry: true`, `key = 1`, `value = 2`) at the point it is called, so its index among
  the nested messages is where protoc's parser would put it, and copies the field's
  `features` onto key and value.
- `optional: true` without `oneof:` gets a synthetic oneof, `_` plus the field name, with
  `X` prepended while the name is taken; synthetic oneofs come after the real ones.
- `group "Result", 1` makes the nested message `Result` and the field `result`.
- A field without `json_name:` gets the derived one (`price_cents` is `priceCents`).

These rules live in `Schema::Draft.map_entry_name`, `.synthetic_oneof_names`,
`.group_field_name` and `Schema.json_name`, and nowhere else. The compiler's parser still
expands maps, groups and proto3 `optional` into its parse tree, because protoc's parser does
and the 90 `parser_unittest.cc` parse cases compare that pre-link tree; it calls the same
four functions to do it.

### Phases

A draft goes through `link`, `resolve` and `freeze!`:

1. **Describe.** Each call creates the real descriptor at once, registers its full name
   and gives it its index among its siblings.
2. **`link(pool)`** finds the dependencies in the pool, completes each message's lookup
   tables (`fields_by_number`, `extension_ranges`, ...), adds synthetic oneofs, and resolves
   every type name, extendee and method type that is not resolved yet. It runs once.
3. **`resolve(pool)`** links if needed, builds each descriptor's options, resolves
   features down the tree (protoc's `FeatureResolver`, `InferLegacyProtoFeatures`,
   `PostProcessFieldFeatures`) and parses defaults. It may run again after options change.
4. **`freeze!`** deep-freezes the graph, makes it shareable and returns the `Schema::File`,
   the same object `draft.descriptor` returned all along.

The split exists for the compiler. To interpret `option (my.opt) = ...` it needs the option
types, which may be declared in the very file being compiled (descriptor.proto's own options
are). So it drafts the file, links it, resolves it once without options, interprets options
against those descriptors, sets them on the draft, and resolves again. Before this
workstream it built the file twice from hashes for the same purpose.

### Why drafts are handles over the real objects

The draft classes (`Draft::File`, `Draft::Message`, `Draft::Enum`, `Draft::Service`) hold
only what is needed to keep describing; the data lives in the descriptors from the first
call. Two alternatives were rejected:

- **Mutable Schema classes with builder methods.** `Message#field(key)` already looks up a
  field; `field(name, number, type)` cannot share the name, and a frozen file would carry
  methods that always raise.
- **A draft data structure converted at `freeze!`.** That is a second representation of
  the same file, which is what this replaced.

### Who drafts

| Caller | How |
|---|---|
| `Protostar::DSL` | its builders are adapters: `m.field :name, 1, :string` is `draft.field("name", 1, :string)`; its spelling (`proto3_optional:`, `m.map :k, 3, :string, :int32`, keyword options) is unchanged, so every generated file loads as before |
| `Compiler::Linker` | drafts each element in `build_file` as it registers its symbols; the symbol table holds the drafted descriptors; `cross_link` records resolved types on them (`__resolve_type`, `__resolve_extendee`, `__resolve_rpc`) |
| `File.from_proto` | reads a `FileDescriptorProto` message into a draft, links it, then decodes options |
| `Draft.copy(file, pool:) { \|descriptor\| options }` | a file rebuilt for another pool with options replaced: the compiler's source-retention-stripped copies |

## Options

Each descriptor's `options` is an instance of the class for its options message:
`FileOptions`, `MessageOptions`, `FieldOptions`, `OneofOptions`, `EnumOptions`,
`EnumValueOptions`, `ServiceOptions`, `MethodOptions`, `ExtensionRangeOptions`. For

```proto
syntax = "proto2";
package acme;
import "google/protobuf/descriptor.proto";
message Limits { optional int32 max = 1; repeated string tags = 2; }
extend google.protobuf.MessageOptions { optional Limits limits = 50001; }
message Order {
  option (limits) = { tags: "a" tags: "b" };
  option (limits).max = 10;
  option deprecated = true;
  optional int32 qty = 1 [default = 1, json_name = "q"];
}
```

```ruby
o = order.options
o                            # => #<Protostar::Schema::MessageOptions deprecated: true, (acme.limits): #<Protostar::Schema::MessageValue tags: ["a", "b"], max: 10>>
o.deprecated?                # => true
o.deprecated                 # => true
o.map_entry                  # => nil
o.extension("acme.limits")   # => #<Protostar::Schema::MessageValue tags: ["a", "b"], max: 10>
o.extension("acme.limits")[:tags]  # => ["a", "b"]
o.extensions.keys            # => [#<Protostar::Schema::Field acme.limits>]
o.features                   # => #<Protostar::Schema::Features {field_presence: :EXPLICIT, enum_type: :CLOSED, ...}>
o[:features]                 # => nil
o.to_proto                   # => #<google.protobuf.MessageOptions deprecated: true>
o.to_proto.unknown_fields    # => [#<Protostar::UnknownField 50001:length_delimited "\b\b\n\x12\x01a\x12\x01b">]
order.field("qty").options   # => #<Protostar::Schema::FieldOptions (none declared)>
```

- **Readers.** Every field of descriptor.proto's options message has one, booleans also a
  `?` form. A reader answers what was declared: nil (an empty Array for a repeated field)
  when the option was not set. descriptor.proto's defaults (`cc_enable_arenas` is true,
  `optimize_for` is `SPEED`) are not applied, because whether an option was set matters to
  protoc's rules (`packed` set to false is not the same as `packed` unset) and to the
  translation back. `options[:name]` and `key?(:name)` are the generic forms.
- **Custom options** are keyed by their extension descriptor: `extensions` is a frozen
  Hash of `Schema::Field` to value, `extension(field_or_full_name)` looks one up. Keying by
  descriptor, rather than by name, means a value can be read and encoded without looking
  anything up again; a file copied into another pool has its options re-keyed to that
  pool's extensions.
- **Values** are Ruby values: Integers, Floats, Strings, true and false, enum values as
  Symbols, repeated fields as Arrays, and message-typed values as `Schema::MessageValue`:
  `value[:field]`, `fields`, `extensions`, `extension(...)`, `unknown_fields`, `merge`,
  `to_h`. `FeatureSet`, `FeatureSupport`, `EditionDefault` and custom message options are
  all MessageValues. `Options` is a MessageValue with readers.
- **`features`** is what the descriptor resolves to, the same object as
  `descriptor.features`; what the file declared is `options[:features]`, a MessageValue.
- **Unknown fields** are wire bytes (`unknown_fields`), as protobuf keeps them: options
  whose extension is not loaded, or not known at all, survive a round trip untouched.
- **`to_proto`** gives the real message of the bootstrap classes, custom options as
  extension bytes it keeps as unknown fields.

### Why not wrap the bootstrap's option messages

The brief suggested that `Options` wrap `Protostar::Google::Protobuf::FieldOptions` and
friends. Three things stand in the way, and `to_proto` gives that message when it is wanted:

1. **A bootstrap cycle.** `descriptor_pb.rb` defines `FieldOptions` by loading
   descriptor.proto through the DSL; descriptor.proto's own fields carry options (`packed`,
   `retention`, `edition_defaults`) that feature resolution needs before the class exists.
2. **Load cost.** Map entries alone carry `map_entry: true`, so nearly every generated file
   would load `descriptor_pb.rb` (about 49 ms) at `require` time; today
   `require "protostar"` loads no `_pb.rb` at all.
3. **Custom options of message types** have no class to be instances of: the compiler
   defines no Ruby classes for what it compiles.

### Giving options to a draft

Draft calls take `options:` as an `Options` or `MessageValue`, or as a Hash in the DSL's
spelling: fields by name, custom options under `extensions:` (by full name or `Field`),
wire bytes under `unknown_fields:`. Message values are Hashes in the same spelling, at any
depth. A custom message type may have a field named `extensions` or `unknown_fields`; give
that field with a String key (`"extensions" => ...`), which the emitter does too. Names are
resolved at `resolve` time against the file, its imports, and the pool; a name that resolves
nowhere is an error. The earlier spellings, `__extensions:` and `__unknown_fields:` as
`[number, wire_type, bytes]` triples, are still read until 0.2.0 with a deprecation warning.

The native emitter writes custom options from `import option` files as `unknown_fields`,
as protoc's own Ruby generator embeds them: a generated file does not load its option-only
imports, so the names might resolve to nothing when it is loaded.

### Where options are wire bytes

Only in `lib/protostar/schema/proto.rb` (`Proto::Codec`), behind `MessageValue#encode(type)`
and `MessageValue.decode(type, bytes, extension_lookup)`. `to_proto` writes options with the
first, `from_proto` reads them with the second, after linking the drafted file so the
file's own extensions are known (one pass; it used to decode twice). The compiler's
text-format reader uses `encode` for `google.protobuf.Any` values in aggregates, which
protoc stores as bytes.

## Reflection

Every message class has a `Message::Reflection`, made when the class is defined, frozen and
shareable, for code that reads and writes messages it does not know in advance:

```ruby
item = Protostar::Types::Registry.new.define(built).fetch("shop.Item")
r = item.reflection          # => #<Protostar::Message::Reflection shop.Item>
it = item.new(name: "lamp")
r.get(it, :name)             # => "lamp"
r.set(it, "price_cents", 1999)
it.price_cents               # => 1999
r.set?(it, :stock)           # => false
r.each(it).map { |f, v| [f.name, v] }  # => [["name", "lamp"], ["price_cents", 1999]]
```

| Method | |
|---|---|
| `klass`, `descriptor` | the class and its `Schema::Message` |
| `fields`, `oneofs`, `field(key)` | descriptors; `key` is a `Schema::Field`, a name (String or Symbol) or a number |
| `get(message, key)`, `set(message, key, value)`, `clear(message, key)` | what the reader and writer do, with the same coercion and errors; `set` to nil clears |
| `set?(message, key)` | set, for a field with presence; non-empty, for repeated and map fields; not zero, for the rest |
| `which(message, oneof)` | the member of a oneof that is set |
| `message_class(key)`, `enum_module(key)` | the class or module a field's values belong to (map values included) |
| `each(message) { \|field, value\| }` | the fields that are set, in declaration order |

It hangs off the class, where it cannot meet a field accessor: a message may have a field
named `reflection`, `fields` or `get`, and instance methods are where those accessors live.
The `__fields`, `__by_name`, `__set` and `__get` names stay as the generated code's fast
paths, `@api private`.

## What changed for readers of the frozen API

| Was | Is |
|---|---|
| `Schema::Builder.build(hash, pool:)` | `Schema::File.draft(...)`, `.resolve(pool)`, `.freeze!` |
| `Schema::Builder.from_proto(msg, pool:)` | `Schema::File.from_proto(msg, pool:)` |
| `Schema::Builder.json_name(name)` | `Schema.json_name(name)` |
| `options[:x]`, `options.key?(:x)` | same, plus a reader per option: `options.x`, `options.x?` |
| `options.extensions["full.name"]` | `options.extension("full.name")`; `extensions` is keyed by `Field` |
| `options.unknown_fields` as `[number, wire_type, bytes]` | wire bytes |
| `options.features` as the declared Hash | resolved `Features`; declared is `options[:features]` |
| `options.to_h` with `:__extensions` | `to_h` for reading, extensions as `:"(full.name)"` keys |
| `Options::EMPTY` for "no options" | `options.declared?` is false; every descriptor's options carry its features |
| `Features#extensions` by full name, Hash values | by `Field`, `MessageValue` values; `Features#with(**core)` |
| `Message#visibility`, `Enum#visibility` as `:VISIBILITY_LOCAL` | `:local` or `:export` |
| `file.to_h` (the working hash) | `to_proto.to_h`, without custom options (they are bytes in `to_proto`) |
| `to_proto(pool:)`, `serialize(pool:)` | `pool:` gone (options hold their extensions); `default_json_names: false` leaves out derived json names |
| `DSL.file_hash`, `DSL.map_entry_hash` | gone; `DSL.file(..., pool:, registry: nil)` builds without defining classes |
| `SourceInfo.new(hash)`, `Location.new(hash)` | `SourceInfo.new(locations)`, `Location.new(path:, span:, ...)` |
| (none) | `Message.reflection`, `MessageValue#encode`/`.decode`, `Field#declared_label`/`#declared_type` (`@api private`) |
