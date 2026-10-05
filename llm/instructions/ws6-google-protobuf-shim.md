# WS6: the google-protobuf shim and gRPC

The crown jewel. A gem literally named `google-protobuf`, living in this repo under
`shims/google-protobuf/`, that satisfies the dependency `grpc` and every other gem
declares on google-protobuf and provides the `Google::Protobuf` Ruby API on top of
protostar, with no native code. Read the WS1 to WS5 reports first. The `.ffi` directory
of the real gem (installed on this machine under
`~/.rbenv/versions/3.4.1/lib/ruby/gems/3.4.0/gems/google-protobuf-4.31.1-arm64-darwin/lib/google/protobuf/`)
is the readable mirror of the C extension's API and is your reference for every method
signature and behaviour; Google's own test suite in `test/corpus/protobuf/ruby/tests/`
is the acceptance test.

## Shape of the gem

```
shims/google-protobuf/
  google-protobuf.gemspec        name "google-protobuf", version "4.36.2.1", dependency "protostar"
  Gemfile                        gemspec + protostar by path + test gems; its own lockfile is ignored
  lib/google/protobuf.rb         the facade entry point
  lib/google/protobuf/*.rb       message_exts, repeated_field, well_known_types, descriptor_pb, *_pb for the WKTs
  lib/google/protobuf_ffi.rb, protobuf_native.rb   tiny stubs so `require` of either succeeds
  test/                          Google's ruby/tests ported, gRPC integration, Bundler resolution
  README.md                      the three install routes
```

The version is numeric so Bundler resolves it without prerelease flags, satisfies
`>= 3.25, < 5.0` (grpc) and `~> 4.36`, and says which upstream API it mirrors. The root
Rakefile gets `shim:test`, which runs the shim's suite from its own directory with its own
Gemfile, and the root CI gets a `shim` job doing the same. The shim's bundle must never
contain the real google-protobuf gem, so it is a separate bundle from the root one; the
oracle group stays in the root Gemfile only.

## Two pools, by design

Native protostar code uses `Protostar.generated_pool` and classes defined by
`Protostar::DSL`. The shim owns a *separate* `Protostar::Schema::Pool` and
`Types::Registry` behind `Google::Protobuf::DescriptorPool.generated_pool`, and every
class it defines carries the Google API. The two never share classes, so a native
`to_h` and a Google `to_h` can differ without either side noticing. A project uses one
style per proto file; a file loaded through both pools yields two class sets, and the
constant clash that follows is a loud error by design. Document this.

The well-known types therefore exist twice: `Protostar::Google::Protobuf::Timestamp`
from the bootstrap (WS4), and `Google::Protobuf::Timestamp` from the shim's own
`lib/google/protobuf/timestamp_pb.rb`, which is a Google-format file our emitter wrote.
The shim's `well_known_types.rb` applies the same helpers WS5 wrote (`Protostar::WellKnown`)
to its classes, aliased to Google's method names.

## The API to implement

Everything a caller of google-protobuf 4.36 can reach, with the behaviour the FFI mirror
and the tests pin:

- `Google::Protobuf` module: `encode`, `decode`, `encode_json`, `decode_json`, `Error`,
  `ParseError`, `TypeError` (< ::TypeError), `IMPLEMENTATION = :PROTOSTAR`,
  `PREFER_FFI`, `Internal::ObjectCache` absent (tests that poke at it go on the
  known-differences list).
- `DescriptorPool`: `generated_pool`, `new`, `add_serialized_file` (decode a
  `FileDescriptorProto` with the bootstrap classes, `Schema::Builder.from_proto`, add,
  define classes; dependency order and re-adding an identical file behave as Google's),
  `lookup` returning `Descriptor`, `EnumDescriptor`, `ServiceDescriptor` or nil.
- `FileDescriptor`, `Descriptor` (Enumerable over fields, `lookup`, `lookup_oneof`,
  `each_oneof`, `msgclass`, `name`, `file_descriptor`, `options`, `to_proto`),
  `FieldDescriptor` (`name`, `json_name`, `number`, `type`, `label`, `default`,
  `submsg_name`, `subtype`, `get`, `set`, `has?`, `clear`, `has_presence?`, `is_packed?`,
  `map?`, `required?`, `repeated?`, `sub_message?`, `wrapper?`, `options`, `to_proto`; map
  fields report `label :repeated`, `type :message` with the entry as `subtype`),
  `OneofDescriptor`, `EnumDescriptor` (`lookup_name`, `lookup_value`, `each`,
  `enummodule`, `options`, `to_proto`), `ServiceDescriptor`, `MethodDescriptor`
  (`input_type`, `output_type`, `client_streaming`, `server_streaming`). `options` return
  the option *messages* (`Google::Protobuf::FieldOptions` and so on, from the shim's
  `descriptor_pb`), frozen, as the gem does. `to_proto` returns the descriptor protos.
- Message classes: `new` with Hash of String or Symbol keys, `decode(bytes,
  recursion_limit:)`, `encode(msg, recursion_limit:)`, `decode_json(str,
  ignore_unknown_fields:)`, `encode_json(msg, preserve_proto_field_names:,
  emit_defaults:, format_enums_as_integers:)`, `descriptor`; instances: accessors, `x=`,
  `has_x?` where the gem defines it, `clear_x`, the oneof reader returning the set
  member's Symbol or nil, `x_const` readers for enum fields via `method_missing`, `[]`,
  `[]=`, `to_h` (the gem's exact inclusion rules, which Google's tests pin), `to_proto`,
  `to_json`, `==`, `eql?`, `hash`, `dup`, `clone`, `freeze`, `frozen?`, `inspect` and
  `to_s` in the gem's format, `MessageExts` included with `ClassMethods` extended (pbbuilder
  monkey-patches `Google::Protobuf::MessageExts::ClassMethods`, so those names must
  exist), `AbstractMessage`.
- `RepeatedField` and `Map`: the whole API of the gem's `repeated_field.rb` and
  `ffi/map.rb`, including the Array-delegated methods, type checks on every write,
  `freeze` semantics, `==` with Arrays, `to_ary`, `hash`, `inspect`.
- Enum modules: constants, `lookup`, `resolve`, `descriptor`.
- Well-known type helpers from `well_known_types.rb`, same names.
- Errors: the gem raises `RangeError` for out-of-range integers, `Google::Protobuf::TypeError`
  for wrong types, `ArgumentError` for unknown fields in `new`, `Google::Protobuf::ParseError`
  for malformed bytes and JSON, `FrozenError` on frozen writes. Map ours to those.
- Enum semantics: the gem keeps unknown numbers of closed enums in the field. WS3 moves
  them to unknown fields as protoc does. Add a decode option in the codec (`closed_enum_unknowns:
  :keep` or similar, the smallest change to `lib/protostar/codec/` that WS3's tests still
  pass with) and use it from the shim; list the change in your report.

How the Google API attaches to classes is yours to decide, within these limits: native
classes and the native runtime stay unchanged; the shim may `prepend` modules and use
`define_method`; repeated and map readers must hand back `RepeatedField` and `Map`
objects that write through to the message, with stable identity for the life of the
message; decoding into shim classes must produce shim instances all the way down.

## Tests

- **Google's suite.** Port `test/corpus/protobuf/ruby/tests/*.rb` into
  `shims/google-protobuf/test/google/` with the smallest edits that make them run under
  `test-unit` against the shim (requires, paths, and the generated `_pb.rb` files for
  their `.proto`s, which you produce with WS4's Google-format emitter at fixture time and
  commit). Run `basic.rb`, `basic_proto2.rb`, `common_tests.rb`, `encode_decode_test.rb`,
  `generated_code_test.rb`, `generated_code_proto2_test.rb`, `multi_level_nesting_test.rb`,
  `repeated_field_test.rb`, `service_test.rb`, `type_errors.rb`, `utf8.rb`,
  `well_known_types_test.rb`. Leave out `gc_test.rb`, `memory_test.rb`, `oom_test.rb`,
  `stress.rb` and `object_cache_test.rb` as implementation-specific. Every remaining
  test passes, except the ones on `test/known_differences.md`, each with one line
  of justification; keep that list short.
- **gRPC.** With the `grpc` gem in the shim's bundle, generate a service with WS4's gRPC
  emitter, run a real server and client in-process over a local port, exercise unary and
  all three streaming shapes, and assert `Google::Protobuf::IMPLEMENTATION == :PROTOSTAR`
  and that no `google/protobuf_native` or FFI library loaded. Also
  `require "google/rpc/status_pb"` from `googleapis-common-protos-types` and build a
  `Google::Rpc::Status` carrying an `Any`.
- **Bundler.** A fixture Gemfile with `gem "grpc"` and `gem "google-protobuf", path:
  "../.."` resolves (`bundle lock` in a temp dir) with no real google-protobuf in the
  lockfile. Document the `github:` + `glob:` form in the README and in the root README.
- **pbbuilder.** Every `Google::Protobuf` method `cheddar-me/pbbuilder`'s `lib/` touches
  (listed in the plan: `descriptor.lookup`, `type`, `label`, `subtype`, `msgclass`,
  `RepeatedField#replace`, `push`, `[]=` on maps, `MessageExts::ClassMethods`) is covered
  by a test here. WS9 runs its full suite.
- Ruby 3.2 and 4.0 as always.

## Out of scope

The legacy `generated_pool.build` DSL (decided out), Ractor shareability of shim classes
(the gem is not Ractor-safe either; do not make things worse but do not chase it),
extensions beyond what the gem supports (it keeps them as unknown fields too).
