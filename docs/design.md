# How protostar is put together

protostar replaces three things Google ships: `protoc` (the compiler), the
`google-protobuf` gem (the runtime), and, through a second gem, that gem's API for code
that cannot change. It is pure Ruby, has no runtime dependencies, and runs on Ruby 3.2 and
later. This page is the map. [compiler-internals.md](compiler-internals.md) and
[schema-api.md](schema-api.md) go deeper into two of its parts.

```
.proto text ──▶ Compiler ──▶ Schema::File ──▶ emitters ──▶ _pb.rb, _pb.rbs, _pb.rbi, _services_pb.rb, .binpb
                                  ▲   │
     DSL (generated _pb.rb) ──────┤   └──▶ Types.define ──▶ message classes ──▶ codec, views, JSON, text, Builder
     FileDescriptorProto bytes ───┘                                   ▲
                                                                       └── shim: Google::Protobuf API on top
```

## The descriptor model

`Protostar::Schema` is the one representation of a `.proto` file: `File`, `Message`,
`Field`, `Oneof`, `Enum`, `EnumValue`, `Service`, `Method`, `ExtensionRange`, with options
as `Schema::Options` objects (a reader per option, custom options keyed by their extension
`Field`, unknown option fields kept as bytes) and editions features resolved down the tree
the way protoc's `FeatureResolver` does. Everything that could be computed is computed when
the file is built: `Field#type`, `#packed?`, `#presence?`, `#json_name`, per-message lookup
tables. A built file is deep-frozen and `Ractor.shareable?`.

Files are built through a draft (`Schema::File.draft`): calls create the real descriptors at
once, then `link`, `resolve` and `freeze!` finish them. The draft also makes what protoc's
parser makes and nobody writes: map entry messages, synthetic oneofs for proto3 `optional`,
group fields, json names. The compiler, the DSL and `File.from_proto` all draft. protoc's
`FileDescriptorProto` appears only at the edges: `to_proto`/`serialize` out, `from_proto`
in. A `Schema::Pool` holds files and answers lookups by full name.

## The compiler

`Protostar::Compiler` is a port of protoc's front end, function by function where that was
practical: the tokenizer, the parser with its error recovery and source locations, the
linker (protoc's symbol table and its exact error messages), option interpretation
including aggregate values in text format, the validator (proto3 rules, JSON name
conflicts, editions features, extension declarations, naming style, symbol visibility),
and source-retention stripping. `google/protobuf/*.proto` are bundled, so imports of the
well-known types resolve without a protoc install. `protostar compile` takes protoc's
flags; `protoc-gen-protostar` is the same thing as a protoc plugin.

The emitters write native Ruby (`--ruby_out`, the DSL), protoc's own google-protobuf Ruby
(`--google_out`, byte for byte what protoc 36.2 writes), RBS and Sorbet RBI for either, gRPC
service stubs (byte for byte what grpc-tools writes) and descriptor sets. Next to native Ruby
the RBS and RBI are written by default; both read their types from one model
(`Emitters::FieldTypes`), so they agree on what every reader returns and every writer takes.
The native `_pb.rb` is `# typed: ignore`: Sorbet cannot follow constants assigned from DSL
calls, and reads the classes from the RBI. The runtime's own signatures are written inline in
`lib/`; `sig/` and `rbi/protostar.rbi` are generated from them (`rake types:generate`).

## Message classes and the codec

`Types.define(file)` makes a class per message and a module per enum. Every method on
them, accessors and codec alike, is generated as Ruby source and `class_eval`ed when the
class is defined. Nothing is `define_method`ed from a block and nothing is cached lazily,
so classes are shareable and work in any Ractor.

A message keeps each field in an instance variable named after its slot (`@_0`, `@_1`,
...), never after the field's name, so no field clashes with `@unknown`, its unknown
fields (kept byte for byte and written back on encode). Every way of making a message
goes through the generated `__reset`, which sets `@unknown` and then every slot in
declaration order, so all messages of a class have one object shape and all classes share
one chain of shapes; YJIT reads and writes fields inline. Readers that return the variable
as it is are copies of `attr_reader`s. Code that walks fields generically (reflection,
JSON, text, `==`, the shim) uses the generated `__slot(i)`, `__set_slot(i, v)` and
`__slots`. Repeated fields are Arrays and maps are Hashes, checked when encoded. Values
are checked and converted on assignment, so a value reads back the way it will decode (a
float field holds the single-precision value). Closed enums put unknown numbers into
unknown fields, as protoc does.

The decoder of a class is a loop over `(buf, pos, limit)` passed as arguments, returning
the position after the message. It dispatches with one `case` over whole tag values (or,
past 16 tags, `<` comparisons down to a `case` of at most 16, which YJIT keeps in
compiled code), reads one- and two-byte varints and fixed-width values inline, maps enum
numbers to names with a literal `case`, and decodes a nested message by calling the
child class's own decoder from the parent's loop, so each call site sees one class. Its
methods live in a module of their own, included into the class, whose constants are the
fields' descriptors. Anything rare (long varints, unknown fields, maps) goes through a
`Wire::Reader` moved to the loop's position first.

`encode` makes one pass into a String: a nested message or packed run gets one byte for
its length, filled in once its bytes are written, and more bytes are spliced in only when
it is over 127 bytes long. `encode_to(io)` and `encode_delimited(io)` cannot take back
what a sink was given, so they make two passes: one records every nested length, the
second writes, flushing as the buffer fills. Both check repeated elements and map entries
in the same order and write the same bytes.

## Views

`Klass.view(bytes)` reads without decoding. Making a view scans the top level of the
message once and records where each field is; nested messages, strings and bytes are not
read until asked for, and a nested message becomes a view of its own. The bytes can be a
String or an `IO::Buffer` (a mapped file, say); nothing is copied. Views follow the
decoder's merge rules exactly, report the same errors at the same offsets, and become
shareable with `freeze_index` over a frozen String.

## JSON and the text format

`Protostar::JSON` writes and reads proto3 JSON as google-protobuf 4.36 does, well-known
types included; stdlib `JSON.parse` gives the tree and protostar walks it against the
descriptors. `Protostar::Text` is protoc's text format, printer and parser, checked against
protoc's own output. Both find the types inside an `Any` through a registry.

## The DSL and generated code

A native `_pb.rb` is a `Protostar::DSL.file` block (the schema, readable, with the
`.proto`'s comments) followed by constants naming the classes, laid out as protoc's Ruby
generator lays them out. Loading it builds the file into `Protostar.generated_pool` and
defines its classes. The DSL can be written by hand; it is a thin layer over the draft.
protostar's own descriptor.proto, plugin.proto and the well-known types are generated this
way into `lib/protostar/google/protobuf/` (under `Protostar::Google::Protobuf`), and a
check fails the build when the compiler would write them differently.

## The Builder

`Protostar::Builder` writes a message's wire bytes as a block runs, without building
message objects, for templates and large responses (pbbuilder's use). It holds back only
what the wire format needs: a nested message until its length is known, and packed runs
until their message ends.

## The google-protobuf shim

`shims/google-protobuf` is a gem named `google-protobuf` (version 4.36.2.1) that provides
Google's Ruby API on protostar: `DescriptorPool`, the descriptor wrappers, message classes
with the gem's methods, `RepeatedField` and `Map`, its errors, the well-known type
helpers. Files generated by protoc call `add_serialized_file`; the shim reads the bytes
with `File.from_proto`, defines protostar classes and gives them the gem's API.

It keeps **two pools**. `Google::Protobuf::DescriptorPool.generated_pool` has its own
`Schema::Pool` and its own type registry, separate from `Protostar.generated_pool`. The
two kinds of generated code (native and Google-format) can then each define
`google.protobuf.Timestamp` without clashing, and each gets the behaviour it was written
for: the shim's classes have open enums and raise `RangeError` for out-of-range integers,
as the gem's do, while native classes keep protoc's closed enums and raise
`Protostar::TypeError`. The price
is that `Google::Protobuf::Timestamp` and `Protostar::Timestamp` are different classes over
the same bytes, and a file loaded both ways has two sets of classes.

## Ractors

The rules, everywhere: anything reachable from a descriptor or a class after it is defined
is frozen and shareable; per-class tables are built at definition time, frozen, and made
shareable after a deep freeze (`Ractor.make_shareable` on a graph with back-references is
quadratic otherwise); generated methods are source, not closures. Decoding, encoding, JSON,
text and views run in any Ractor; messages decoded with `frozen: true` cross Ractor
boundaries. Defining classes (loading `_pb.rb` files) belongs in the main Ractor, before
others start. The Builder caches a class per message on first use in the main Ractor and
makes its own elsewhere.

## Testing

Four tiers, each against Google's own artefacts rather than our idea of them:

1. **The corpus.** `test/corpus/protobuf/` is a slice of protobuf v36.2: 107 `.proto` files
   with protoc 36.2's descriptor sets for each (`test/corpus/goldens/`). The compiler must
   produce them exactly, source locations included; the emitters must reproduce protoc's
   and grpc-tools' generated files byte for byte; the 239 parser and 28 source-info cases of
   `parser_unittest.cc` and 116 recorded validation errors must match. Every message type in
   the corpus round-trips through the codec, views, the text format and the Builder.
2. **The oracle.** With `BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`, the C-extension gem
   decodes what protostar encodes and the other way round, and JSON is compared byte for
   byte, for random instances of every corpus message.
3. **Conformance.** protobuf's own `conformance_test_runner` (6,558 tests: binary, JSON,
   text format, proto2, proto3 and editions) runs against `conformance/run_testee`. One
   test fails, on purpose and on a list: UTF-8 validation of a string extension, which
   needs extensions as fields.
4. **Other people's suites.** Google's Ruby tests run unchanged against the shim, along
   with a gRPC server and client, every file of `googleapis-common-protos-types`, 576
   probes recorded from the C gem, and pbbuilder's own suite (on the shim and on
   `Protostar::Builder`). `test/release/` installs the built gems into an empty GEM_HOME
   and uses them with no bundle.
