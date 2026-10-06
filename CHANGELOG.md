# Changelog

## 0.1.0

The first release. protostar and the `google-protobuf` shim (4.36.2.1) are released
together and depend on each other's exact version.

### Compiler

- `Protostar::Compiler`: protoc 36.2's front end in Ruby (tokenizer, parser, linker, option interpretation, validation, source-retention stripping) for proto2, proto3 and editions; descriptors equal protoc's on all 107 files of protobuf's own test corpus, source info included.
- Errors and warnings as protoc prints them (gcc or msvs format), with protoc's wording for 239 parser and 116 validation cases.
- The well-known types and `descriptor.proto` are bundled, so their imports need no include path.
- `protostar compile` with protoc's flags: `--ruby_out` (protostar's classes), `--google_out` (byte for byte protoc's `--ruby_out`), `--rbs_out`, `--grpc_out` (byte for byte grpc-tools'), `--descriptor_set_out` (byte for byte protoc's, with `--include_imports` and `--include_source_info`).
- `protoc-gen-protostar`, the same outputs as a protoc plugin (`ruby`, `google`, `rbs`, `grpc`).

### Schema

- `Protostar::Schema`: frozen, Ractor-shareable descriptors (`File`, `Message`, `Field`, `Oneof`, `Enum`, `Service`, ...) with editions features resolved and lookup tables built once.
- `Schema::File.draft` builds descriptors by hand: map entries, synthetic oneofs, groups and json names made by protoc's rules.
- Options as objects: a reader per option, custom options by extension (`options.extension("acme.limits")`), unknown option fields as bytes.
- `to_proto`, `serialize` and `File.from_proto` translate to and from protoc's `FileDescriptorProto`; `Pool#add_serialized_file`, `Protostar.load_descriptor_set`.

### Messages

- Message classes generated from the schema, with accessors, `has_`/`clear_`/`which_`, `[]`/`[]=`, `to_h`, `==`, `dup`, `freeze`, `inspect` and `pretty_print`; values checked on assignment.
- Binary encode and decode, delimited streams, encoding to an IO; unknown fields kept byte for byte; closed enums as protoc treats them; `DecodeError` with the byte offset; recursion limits.
- Decoding from an `IO::Buffer` in place; `decode(bytes, frozen: true)` for shareable messages; everything usable inside Ractors.
- Views: `Klass.view(bytes)` reads fields from a String or `IO::Buffer` without decoding the rest.
- Proto3 JSON (`to_json`, `encode_json`, `decode_json`) as google-protobuf 4.36 writes it, including the well-known types; `JSON.pretty_generate` works.
- protoc's text format (`to_text`, `Protostar::Text.print`, `.parse`), checked against protoc's own output.
- Well-known types with google-protobuf's helpers and short names (`Protostar::Timestamp`, `Any.pack`, `Struct.from_hash`, ...); `Time` assigns to a Timestamp field and a number to a Duration field.
- `Klass.reflection`: read and write fields by descriptor, name or number.
- `Protostar::Builder` and `Klass.build`: write a message's bytes as a block runs, with streaming to an IO and fragment caching.
- `Protostar::DSL`: the generated `_pb.rb` format, readable and writable by hand; RBS for the generated classes.
- Passes protobuf's conformance suite: 6,557 of 6,558 tests (binary, JSON and text format); the one failure needs extensions as fields.

### The google-protobuf shim

- `shims/google-protobuf`: a gem named `google-protobuf` providing Google's `Google::Protobuf` API on protostar, so `grpc`, `googleapis-common-protos-types` and protoc's generated files run unchanged. Google's own Ruby tests pass against it.
- Its own descriptor pool, so native and Google-format generated code can be loaded side by side.

### Development

- `rake test` runs the test files in a forked worker per core, sharded by recorded timings (about 15 s instead of 66 s on 10 cores); `PARALLEL=0` keeps the serial run. The shim's suite uses test-unit's process workers.

### Deprecated

- `Compiler#compile_to_hashes`: use `compile` and `to_proto`. Goes away in 0.2.0.
- In `Protostar::DSL` and draft options: `__extensions:` (now `extensions:`), `__unknown_fields:` triples (now `unknown_fields:` bytes) and `visibility: :VISIBILITY_EXPORT` (now `:export`). Read with a warning until 0.2.0; `protostar compile` writes the new spelling.

### Not supported

- Extensions as first-class fields (their bytes are kept; text format, JSON and the shim read them by name).
- `_pb.rb` files from protoc before 3.21 (the `add_file` DSL).
