# Changelog

## 0.1.0

The first release. protostar and the `google-protobuf` shim (4.36.2.1) are released
together and depend on each other's exact version.

### Compiler

- `Protostar::Compiler`: protoc 36.2's front end in Ruby (tokenizer, parser, linker, option interpretation, validation, source-retention stripping) for proto2, proto3 and editions; descriptors equal protoc's on all 107 files of protobuf's own test corpus, source info included.
- Errors and warnings as protoc prints them (gcc or msvs format), with protoc's wording for 239 parser and 116 validation cases.
- The well-known types and `descriptor.proto` are bundled, so their imports need no include path.
- `protostar compile` with protoc's flags: `--ruby_out` (protostar's classes), `--google_out` (byte for byte protoc's `--ruby_out`), `--rbs_out`, `--grpc_out` (byte for byte grpc-tools'), `--descriptor_set_out` (byte for byte protoc's, with `--include_imports` and `--include_source_info`).
- `protostar file.proto` just works: `compile` is the default command, without `-I` each input's directory is the include path (the file is named by its basename), and one file with no `--*_out` prints its native Ruby to stdout. Explicit `-I` behaves as protoc's.
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
- `Protostar::Builder` streams to any sink (`write`, `<<` or `call`) with a `buffer:` size, hands nested messages larger than the buffer to the sink without a copy, splits large nested messages into merged pieces with `chunk_nested_at:` (100 MB held 0.13 MB instead of 256 MB), writes length-prefixed sequences with `Builder.each` and Enumerators with `Builder.each_chunk`, and holds packed varint runs as bytes (116 MB down to 32 MB for 10 M int32). See [docs/concepts/streaming.md](docs/concepts/streaming.md).
- `Protostar::DSL`: the generated `_pb.rb` format, readable and writable by hand; RBS for the generated classes.
- Passes protobuf's conformance suite: 6,557 of 6,558 tests (binary, JSON and text format); the one failure needs extensions as fields.

### The google-protobuf shim

- `shims/google-protobuf`: a gem named `google-protobuf` providing Google's `Google::Protobuf` API on protostar, so `grpc`, `googleapis-common-protos-types` and protoc's generated files run unchanged. Google's own Ruby tests pass against it.
- Its own descriptor pool, so native and Google-format generated code can be loaded side by side.

### Development

- `to_proto` no longer calls `require` once descriptor.proto's classes are loaded, so it works inside a Ractor on Ruby 3.2 and 3.3 when the main Ractor loaded them first.
- `require "protostar"` loads the schema, the wire format and the binary codec only: 28 files in 8.6 ms instead of 85 files in 54 ms (Ruby 3.4, M1 Pro). The compiler, JSON, text format, views, builder, DSL, well-known helpers and descriptor.proto's classes (`Protostar::Google::Protobuf::*`, long names too) are autoloaded on first use; loading and decoding a Timestamp takes 17.5 ms instead of 57. In a program with Ractors, touch what a Ractor will use in the main Ractor first.
- `rake test` runs the test files in a forked worker per core, sharded by recorded timings (about 15 s instead of 66 s on 10 cores); `PARALLEL=0` keeps the serial run. The shim's suite uses test-unit's process workers.

### Deprecated

- `Compiler#compile_to_hashes`: use `compile` and `to_proto`. Goes away in 0.2.0.
- In `Protostar::DSL` and draft options: `__extensions:` (now `extensions:`), `__unknown_fields:` triples (now `unknown_fields:` bytes) and `visibility: :VISIBILITY_EXPORT` (now `:export`). Read with a warning until 0.2.0; `protostar compile` writes the new spelling.

### Not supported

- Extensions as first-class fields (their bytes are kept; text format, JSON and the shim read them by name).
- `_pb.rb` files from protoc before 3.21 (the `add_file` DSL).
