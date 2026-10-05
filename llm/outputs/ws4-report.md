# WS4 report: bootstrap, emitters and the CLI

## What was built

| File | Contents |
|---|---|
| `lib/protostar/dsl.rb` | `Protostar::DSL`: `file`, `file_hash`, `message`, `enum`, `service`, `map_entry_name`; builders for files, messages, oneofs, `extend` blocks, enums, services |
| `lib/protostar/schema/proto.rb` | `Protostar.generated_pool`, `Protostar.load_descriptor_set`, `Protostar::Pool` (= `Schema::Pool`), `Schema::File#to_proto`/`#serialize`, `Schema::Builder.from_proto`, `Pool#add_serialized_file`/`#load_descriptor_set`, and `Schema::Proto::HashCodec` |
| `lib/protostar/compiler/emitters.rb` | `Emitters::BOOTSTRAP`, `Naming` (protoc's Ruby naming rules), `Printer` (protoc's io::Printer indentation), `Literal` (Ruby literals) |
| `lib/protostar/compiler/emitters/ruby.rb` | native `_pb.rb` (the DSL) |
| `.../google_ruby.rb` | protoc's `ruby_generator.cc` output |
| `.../rbs.rb` | protoc's `rbs_generator.cc` output |
| `.../grpc.rb` | grpc's `src/compiler/ruby_generator.cc` output (`_services_pb.rb`) |
| `.../descriptor_set.rb` | `--descriptor_set_out` bytes |
| `lib/protostar/cli.rb`, `exe/protostar` | `protostar compile`, `protostar --version` |
| `lib/protostar/plugin.rb`, `exe/protoc-gen-protostar` | the protoc plugin |
| `lib/protostar/google/protobuf/*_pb.rb` (12 files, 2,780 lines) | the bootstrap: descriptor, compiler/plugin and the 10 well-known types |
| `script/bootstrap.rb` | `rake bootstrap:check`, `rake bootstrap:regenerate` |
| `script/record_grpc_goldens.rb` | records `test/corpus/generated/grpc/out/` with grpc-tools |

### How it works

- **DSL.** `DSL.file` turns its block into the exact `FileDescriptorProto` hash protoc would make (map entries, group
  messages and proto3 synthetic oneofs are synthesized the way protoc's parser does), `Builder.build`s it against
  `Protostar.generated_pool`, adds it and `Types.define`s it in the global registry. Loading a file the pool already
  has returns that file without running the block. Every descriptor-level call takes its options as keywords
  (`deprecated: true`, `packed: false`, `features: {...}`), custom options under `extensions: {"full.name" => v}`;
  `options: {...}` takes the hash verbatim (`:__extensions`, `:__unknown_fields`, or `{}` for an empty options
  message). Sugar: `m.map`, `m.oneof { |o| ... }`, `m.group "Name", n { |g| ... }`, `x.extend ".pkg.Msg" { |e| ... }`,
  `m.extensions 100..199`, `m.reserved 5, 9..11, "name"`, `default:` as protoc stores it.
- **Native emitter.** Writes the DSL, then constants (`module Acme; Person = Protostar::DSL.message("acme.Person")`)
  named exactly as protoc's Ruby generator names them (ruby_package, PackageToModule, RubifyConstant incl. `PB_`,
  map entries skipped). Leading comments from source info become `#` comments. Where the sugar cannot reproduce the
  descriptor (oneofs out of order or not contiguous, unusual synthetic oneof names, map entries with extra options,
  sugar whose nested-type order would differ) it falls back to plain `m.oneof :x` / `oneof:` / `m.message` calls.
  Output is `standard`-clean.
- **Descriptors to bytes.** `HashCodec` encodes and decodes descriptor-shaped hashes driven by `Schema` descriptors,
  so any custom option type works: fields in number order, extensions from `:__extensions` (looked up through the
  file's transitive imports, then an optional pool for `import option` files), `:__unknown_fields` last, packed
  repeated per features, MessageSet items for `message_set_wire_format` types, proto3 zero values skipped. The
  bootstrap classes are only used at the edges (`to_proto` decodes the bytes into a `FileDescriptorProto`).
  Decoding resolves extensions through the pool; when a file's options use extensions the file itself defines,
  a first-pass build of the file supplies them for a second decode.
- **Bootstrap.** Generated with the native emitter from the bundled includes, with source comments. Constants live
  under `Protostar::Google::Protobuf` (see deviations); `require "protostar/google/protobuf/descriptor_pb"` etc.
  `Schema::Proto.types` requires `descriptor_pb` lazily, so `require "protostar"` does not load it.

## Tests

388 new runs (1,705 in the suite). `bundle exec rake` clean (tests and standard): 1,705 runs, 0 failures, 325
skips (all pre-existing oracle skips). With `BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`: 1,705 runs, 172,947
assertions, 0 skips. Green on Ruby 3.4.1, 3.2.2 and 4.0.0. Suite time went from 13s to 35s (the three per-golden
corpus tests take about 20s together).

| File | Runs | Covers |
|---|---|---|
| `test/emitters/ruby_corpus_test.rb` | 107 | every corpus golden: emit every file of the set with source comments, load in a fresh process (goldens packed into 3 processes so no two differing definitions meet), `to_h` equals the compiler's (custom options included) and, stripped, the golden JSON; every message and enum under protoc's constant name; shareable; re-emitting from the loaded descriptors gives the same text; no warnings |
| `test/emitters/descriptor_set_test.rb` | 109 | every `.binpb` golden reproduced byte for byte with `--include_imports --include_source_info`; without imports/source info; import order |
| `test/bootstrap/descriptor_set_test.rb` | 107 | every `.binpb` through `load_descriptor_set` with our codec only: equals the compiler's descriptors with source info and custom options, equals the golden JSON, re-serializes to the same bytes |
| `test/bootstrap/bootstrap_test.rb` | 7 | `bootstrap:check` passes, all 12 files committed and loading, equal to the bundled protos, constants under `Protostar::Google::Protobuf` (and not the oracle's when it is loaded), requires point at the bootstrap, `to_proto` round trip, shareable classes |
| `test/bootstrap/proto_test.rb` | 6 | custom options as extension bytes, `from_proto` from messages and bytes, unknown extensions kept and re-serialized, MessageSet items, Pool conveniences |
| `test/emitters/protoc_ruby_test.rb` | 13 | Google format and RBS byte equality with the 5 corpus goldens each, output names, RubyEscape, banned `ruby_package` |
| `test/emitters/grpc_test.rb` | 7 | byte equality with 4 grpc-tools goldens, no file without services, output names |
| `test/emitters/dsl_test.rb` | 8 | hand-written DSL builds exactly what the compiler builds for a proto3 file (maps, oneofs, optional, custom options, services), a proto2 file (groups incl. in a oneof, defaults, extensions, aliases, MessageSet) and an editions file; idempotent load; lookups; verbatim options; bad input |
| `test/emitters/ruby_emitter_test.rb` | 9 | the emitter's fallbacks, literals (escapes, binary, `#{`, invisible code points), comments, constant naming, namespaces and requires |
| `test/cli/cli_test.rb` | 11 | subprocess runs over `test/fixtures/project`: every flag, outputs equal the emitters', the generated Ruby loads and round-trips a message, disk-path inputs, gcc and msvs diagnostics with disk paths, warnings, every command-line mistake protoc reports, generator errors, nothing written on failure |
| `test/cli/plugin_test.rb` | 4 | hand-built `CodeGeneratorRequest` through stdin and in process: outputs, supported features, editions range, errors in the response |

## Goldens: byte for byte or not

- **Descriptor sets**: 107/107 `.binpb` byte for byte, custom options and MessageSet items included. No hash fallback
  was needed, so there is no protoc-serializer difference to explain.
- **Google format**: the 5 corpus goldens (the spec said four; `ruby_generated_pkg_explicit_legacy` is the fifth)
  byte for byte. A one-off sweep against protoc 36.2 (not a test: tests must not need protoc) matched all 107
  corpus files.
- **RBS**: the 5 corpus goldens byte for byte; the sweep matched all 103 non-editions corpus files. protoc's RBS
  generator refuses editions files, and so do we (below).
- **gRPC**: 4/4 grpc-tools goldens byte for byte: `ruby/tests/service_test.proto` and three of ours under
  `test/corpus/generated/grpc/protos` (every streaming combination, nested and imported types, `ruby_package`,
  lower-case and snake_case names, leading/trailing/detached comments, a `$` in a file comment, no package, a
  service without methods). grpc-tools 1.84.0 (its libprotoc is 35.1) was installed into a throwaway GEM_HOME; it is
  not in the Gemfile.
- The native format has no outside golden; its check is the round trip above.

## Deviations from the spec, and why

1. **Bootstrap namespace (the coordinator's rule).** Bootstrap constants are `Protostar::Google::Protobuf::*`
   (`Protostar::Google::Protobuf::Compiler::*` for plugin.proto), files required as
   `protostar/google/protobuf/<name>_pb`. Mechanism: the native emitter takes `namespaces: {file name => "A::B"}`,
   which replaces the package-derived module path for those files; `script/bootstrap.rb` passes
   `"Protostar::" + <protoc's path>` for the 12 files. No `namespace:` argument on `DSL.file` was needed, because
   `DSL.file` never places constants: the emitted constant block after it does, and that block is what the
   namespace changes. Separately, `Emitters::Ruby.new(bootstrap_requires: true)` (the default) writes
   `require "protostar/google/protobuf/<name>_pb"` for imports of the 12 bootstrap files; other imports keep
   protoc's relative `require "foo/bar_pb"`. The Google-format emitter is unaffected.
2. **`DSL.service` returns an unfrozen Module** answering `descriptor`, so grpc's `module Greeter; class Service`
   reopens it. Services were not in protoc's Ruby output; the spec's example has them.
3. **Options as keywords.** "Known ones as keywords" is read as keywords on each call (`m.field ..., packed: true`),
   custom ones under `extensions:`. Inside option values (nested messages) extensions keep the hash spelling
   `__extensions:`, because the DSL cannot know whether a nested message has a field named `extensions`.
4. **Google format and `json_name`.** protoc embeds `json_name` only where the `.proto` set one; the Schema does not
   record that, so a `json_name` equal to the derived one is treated as not set. A `.proto` that spells out the
   default json_name gets a descriptor blob without it (protoc's has it). No corpus file does this.
5. **RBS refuses editions files** with protoc's exact message, in the CLI and the plugin, since protoc's
   `--rbs_out` does. The RBS for native files is the same as for the Google format (`< ::Google::Protobuf::AbstractMessage`
   and all), as the spec asks; it describes google-protobuf's API shape.
6. **CLI details pinned to protoc 36.2**: default `-I.`; bundled includes after `-I`; `--proto_path` accepts
   `a:b`; inputs may be disk paths under an include path or virtual names (protoc's MakeInputsBeProtoPathRelative,
   except the "shadowed" case, which is not reported); output directories must exist (`dir/: No such file or
   directory`); every output is generated before anything is written. The CLI compiles with source info always
   (comments), and strips it from descriptor sets unless `--include_source_info`.
7. **Plugin parameter**: `ruby` (default), `google`, `rbs`, `grpc`, comma-separated; `ruby` and `google` together
   are refused (both write `*_pb.rb`). It declares proto3 optional and editions, EDITION_PROTO2 to EDITION_2024.
8. **Additions**: `DSL.file_hash`, `MessageBuilder#group`, `Emitters::Ruby#definition`, `Schema::File#serialize`
   (and `extension_finder`, `@api private`), `Pool#add_serialized_file`, `Pool#load_descriptor_set`, `Protostar::Pool`.
9. **`from_proto` keeps unknown fields only inside options** (`:__unknown_fields`); unknown fields elsewhere in a
   `FileDescriptorProto` are dropped, since the Builder has nowhere to put them.

## Changes to other workstreams' files

- `lib/protostar/compiler.rb`: `Diagnostic#path` (disk path as protoc prints it, nil for in-memory and bundled
  files) and `Diagnostic#format(:gcc | :msvs)`; `Compiler#disk_path`, `Compiler.canonical_path` (protoc's
  CanonicalizePath). `Diagnostic#to_s` and equality are unchanged.
- `lib/protostar/compiler/run.rb`: fills `path` when reporting (one line).
- `lib/protostar.rb`: requires `schema/proto`, `dsl`, `compiler/emitters`. `Rakefile`: the bootstrap tasks.
- `lib/protostar/schema/proto.rb` is new and reopens `Schema::File`, `Schema::Builder` and `Schema::Pool` to add
  the methods above; no existing schema file was touched. `lib/protostar/types.rb` is untouched.

## Schema or codec changes requested

None needed; worked around locally:
- Whether `json_name` was explicit is not kept (deviation 4). A `Field#json_name_explicit?` (or keeping the raw
  value) would make the Google format exact.
- `option_dependencies` are not linked, so extensions from `import option` files are found through a pool passed to
  `to_proto(pool:)`, `GoogleRuby.new(pool:)` and `DescriptorSet.new(pool:)`.
- The corpus never trips `Pool#add`'s cross-file extension clash.

## For WS6 (google-protobuf shim)

- `Protostar::Google` now exists once the bootstrap is loaded. Code inside `module Protostar` that means the shim's
  `Google::Protobuf` must write `::Google::Protobuf`.
- The bootstrap registers `google.protobuf.*` full names in the **global** `Types.registry`; a shim defining its own
  `google.protobuf.Timestamp` must use its own `Types::Registry` and `Schema::Pool`, or `Registry#define` raises.
- Google-format files call `DescriptorPool.generated_pool.add_serialized_file(bytes)` and
  `lookup(name).msgclass/.enummodule`; `Schema::Pool#add_serialized_file` (custom options decoded against the pool)
  and `Protostar.load_descriptor_set` are there to build on.
- grpc stubs reference `::Google::Protobuf::Empty` and the like for well-known types and expect `encode`/`decode`
  class methods; in the native world those constants are `Protostar::Google::Protobuf::*`. Whether the shim
  aliases them is for WS6 to decide.
- Open question: should the native emitter offer a flag that also places constants under `Google::Protobuf` for
  imports of the well-known types, for users without the shim?

## For WS7 (conformance)

- `test_messages_proto2/3` and the editions variants emit, load and round-trip through the native emitter; their
  classes can come from `protostar compile --ruby_out` or straight from `DSL.file`.
- `protoc-gen-protostar` works under real protoc 36.2 (checked by hand with `--protostar_out=google,rbs` against
  protoc's own `--ruby_out --rbs_out`: identical).

## Open questions

1. Should `DSL.file` check that a second load describes the same file instead of returning the first silently?
2. Should `--ruby_out` and `--google_out` into the same directory be refused by the CLI as the plugin does?
3. Should the gRPC goldens also be recorded with a grpc-tools whose libprotoc matches 36.2 once one exists?
