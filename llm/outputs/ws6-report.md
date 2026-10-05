# WS6 report: the google-protobuf shim

## What was built

A gem named `google-protobuf`, version `4.36.2.1`, under `shims/google-protobuf/`, depending on `protostar`
(exactly the repo's version). No native code, no FFI. `IMPLEMENTATION == :PROTOSTAR`.

| File (under `shims/google-protobuf/`) | Contents |
|---|---|
| `google-protobuf.gemspec`, `Gemfile`, `Rakefile` | gem; own bundle (protostar by path, rake, test-unit, bigdecimal, grpc, googleapis-common-protos-types); `rake test`, `rake generate`, `rake generate:check` |
| `lib/google/protobuf.rb` | errors (`Error`, `ParseError`, `TypeError < ::TypeError`, `UnexpectedStructType`), `PREFER_FFI`, `IMPLEMENTATION`, `encode`/`decode`/`encode_json`/`decode_json`/`deep_copy`/`discard_unknown`, the generated pool |
| `lib/google/protobuf/descriptor_pool.rb` | `DescriptorPool`: own `Schema::Pool` + `Types::Registry.new(open_enums: true)`, `add_serialized_file` (through `Schema::Proto.build`), `lookup`, one wrapper per schema descriptor, map entry classes on request, `build` raising a clear `NotImplementedError` |
| `lib/google/protobuf/descriptors.rb` | `Descriptor`, `FieldDescriptor`, `OneofDescriptor`, `EnumDescriptor` (+ enum modules), `ServiceDescriptor`, `MethodDescriptor`, `FileDescriptor`; `options` (frozen, without `features`) and `to_proto` as messages of the shim's `descriptor_pb` |
| `lib/google/protobuf/message.rb` | turns each registry class into a Google message class: `MessageExts`, class methods, instance methods, per-class accessor module (prepended) |
| `lib/google/protobuf/repeated_field.rb`, `map.rb` | containers over the message's own Array/Hash, checked on every write, the gem's full API incl. the Array-delegated and Array-wrapper methods |
| `lib/google/protobuf/internal/convert.rb` | value conversion with the gem's rules and messages (incl. Ruby's NUM2INT wording for out-of-range integers) |
| `lib/google/protobuf/internal/extensions.rb` | extension get/set/has/clear over unknown fields (MessageSet items included) |
| `lib/google/protobuf/internal/json.rb` | JSON through `Protostar::JSON` with the gem's options and errors; top-level extensions as `"[full.name]"` |
| `lib/google/protobuf/message_exts.rb`, `well_known_types.rb` | as the gem's; `AbstractMessage` (private constant) |
| `lib/google/protobuf/*_pb.rb` (12), `plugin_pb.rb` | written by protostar's Google-format emitter (`script/generate.rb`); 9 of 11 byte-identical to google-protobuf 4.31.1's (api, descriptor differ by protobuf version) |
| `lib/google/protobuf_ffi.rb`, `protobuf_native.rb` | stubs requiring `google/protobuf` |
| `script/generate.rb` | regenerates the WKT files and every test fixture with protostar's compiler; `check` mode |
| `script/record_differential.rb` | records Google's gem's results for the differential probes |
| `README.md`, `test/known_differences.md` | install routes (GitHub/glob, path, private source), coverage, the two-pool rule |

### How it works

- `add_serialized_file` decodes with protostar's bootstrap, builds into the pool's own `Schema::Pool`, defines classes in
  the pool's own `Types::Registry` (so `google.protobuf.*` never clashes with the global registry), then
  `Internal::MessageClass.setup` gives each class the gem's API: `include MessageExts, MessageMethods`,
  `extend ClassMethods`, and `prepend` a module of `define_method` accessors (prepending avoids redefinition warnings
  and wins over protostar's generated accessors). Native classes are untouched.
- `klass.descriptor` returns the `Google::Protobuf::Descriptor` wrapper; it delegates by name the few methods
  protostar's runtime reads from it (`full_name`, `file`, `fields_by_name`, `fields_by_json_name`, ...), so protostar's
  JSON, Any and codec keep working on shim classes.
- Values live in protostar's slot Array; `RepeatedField`/`Map` wrap the stored Array/Hash and are cached per slot, so a
  field reads as the same object while it holds the same storage (`m.repeated_int32 = rf` stores `rf`'s Array and
  caches `rf`, which the gem's tests require). Frozen messages hand out frozen, cached wrappers.
- Writes go through `Internal::Convert` (gem semantics) and store directly; reads use protostar's slots.
- Extensions are unknown fields (protostar's model): `FieldDescriptor#get/set` reads and writes them with
  `Protostar::Text::Extensions`; `==` compares extension bytes too; `discard_unknown` keeps them.

## Tests

`bundle exec rake test` in `shims/google-protobuf`: **992 tests, 0 failures, 44 omissions**, identical on Ruby 3.2.2,
3.4.1 and 4.0.0. `rake generate:check` passes (29 generated files up to date).

| Path | Tests | Covers |
|---|---|---|
| `test/google/` (Google's suite, unchanged files) | 316 | `basic.rb` 133, `basic_proto2.rb` 93, `encode_decode_test.rb` 9, `generated_code_test.rb` 1, `generated_code_proto2_test.rb` 1, `multi_level_nesting_test.rb` 1, `repeated_field_test.rb` 40, `service_test.rb` 10, `type_errors.rb` 8, `utf8.rb` 12, `well_known_types_test.rb` 8; `common_tests.rb` runs inside both basic files. **314 pass, 2 omitted by Google's own conditions, 0 fail** |
| `test/differential/` | 577 | 576 probes vs google-protobuf 4.36.2 (C gem) recorded by `script/record_differential.rb`; 534 equal, 42 marked known differences with reasons |
| `test/grpc/grpc_test.rb` | 8 | real grpc 1.84.0 server + client in process over 127.0.0.1: unary, client, server and bidi streaming, WKT request/response, rich error details via `google/rpc/status_pb` + `Any`; asserts `:PROTOSTAR`, gem path is the shim, no `protobuf_c`/FFI loaded |
| `test/grpc/ecosystem_test.rb` | 60 | all 59 `_pb.rb` files of googleapis-common-protos-types 1.23.0 and grpc's health service load; each `FileDescriptor#to_proto` re-encodes **byte for byte** to protoc's embedded descriptor; every message round-trips binary and JSON |
| `test/bundler/bundler_test.rb` | 3 | `bundle lock` in a temp dir with `gem "grpc"` and the shim from `path:`, from a `git ... glob:` block, and per-gem `git:`+`glob:` (the README's github form): shim locked, no google-protobuf under GEM |
| `test/pbbuilder/pbbuilder_api_test.rb` | 11 | every call pbbuilder's `lib/` makes: `MessageExts::ClassMethods` patched before classes exist, `descriptor.lookup`, `type`, `label`, `subtype.msgclass` (map entries too), `[]`/`[]=`, `RepeatedField#replace`/`push`, `Map#[]=`, `to_h` |
| `test/shim/` | 17 | two pools (native vs shim WKT classes, DSL files invisible to the shim pool, one file in two pools), pool errors, lookups, `to_proto` == embedded bytes, containers' identity and write-through, decode gives shim classes all the way down, open closed-enums, extensions on options/messages/MessageSets/JSON, dup vs deep_copy, frozen behaviour, recursion limits and cycles, Time/Numeric to Timestamp/Duration, map entry classes |

Root suite: `bundle exec rake` clean (1,929 runs, 0 failures, 335 skips as before; standard clean incl. `shims/`).
Green on 3.2.2, 3.4.1, 4.0.0; with `BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`: 1,929 runs, 189,959 assertions, 0 skips.

**pbbuilder's own suite** (cheddar-me/pbbuilder 0.20.0, Rails 8.1.4) against the shim, checked by hand in a scratch
Gemfile: 35 runs, 75 assertions, 0 failures, 1 skip (theirs, `skip("This will be addressed...")`).

## Known differences (`test/known_differences.md`)

Google's tests: none fail. Omitted by their own guards: `test_dup_extensions` in `basic.rb` (proto3 module has no
`TestExtensions`; passes in `basic_proto2.rb`) and `test_service_options_extensions` (guarded on
`IMPLEMENTATION == :NATIVE`; the same assertion passes in `test/shim/messages_test.rb`). Not ported, per spec:
`gc_test`, `memory_test`, `stress`, `object_cache_test`; also `implementation.rb` (expects `:NATIVE`/`:FFI`) and
`ruby_version.rb`. There is no `oom_test.rb` in the pinned corpus.

Against the C gem (marked in `probes.txt`): descriptors inspect like the FFI implementation's (name, no address) and
their names are frozen UTF-8; accessors are real methods (not `method_missing`), protostar's extra message methods
(`encode`, `to_text`, `merge!`, ...) exist; lookups accept Strings and Symbols; `each` without a block returns an
Enumerator; maps iterate/encode in insertion order; JSON error wording is protostar's (class matches); JSON handles
extensions of the top-level message only.

## Deviations from the spec, and why

1. **Closed-enum option is a registry flag, not a codec decode option.** `Types::Registry.new(open_enums: true)`
   makes `FieldInfo#closed_enum` false for every field of that registry's classes. Closed-enum handling is baked into
   each class's generated decoder and also used by coercion, JSON and text; a per-call option would have to be
   threaded through every generated `__decode_fields`. The flag costs nothing at runtime, changes no codec file, and
   also makes assignment of unknown numbers work (the gem allows `m.optional_enum = 999` on proto2).
2. **Shim classes subclass `Protostar::Message`, not `AbstractMessage`.** The registry makes `Class.new(Message)`;
   `AbstractMessage` exists (private constant, includes `MessageExts`) but is not an ancestor. `is_a?(MessageExts)`
   holds. No test or library seen checks the superclass.
3. **Descriptor `inspect`, `map?`, `sub_message?`, `wrapper?`, `Descriptor.new` raising RuntimeError** follow the FFI
   implementation (the spec's reference); the C gem differs (listed above).
4. **Google's test files keep their names** (`basic.rb`, `utf8.rb`, ...); their generated `_pb.rb` sit next to them in
   `test/google/` so the files run with zero edits; the Rakefile lists the four that are not `*_test.rb`.
5. **`known_differences.md` is in `test/`** (the spec names it there) and is not shipped in the gem.
6. **Duplicate `add_serialized_file` always raises** (`duplicate file name`), even for identical bytes: the C gem does,
   which the spec's "behave as Google's" asks for.
7. Additions: `test/differential/` (recorded diff against 4.36.2), `test/grpc/ecosystem_test.rb`,
   `lib/google/protobuf/plugin_pb.rb` (the gem ships plugin's classes under that path too).

## Changes outside `shims/`

- `lib/protostar/types.rb`, `lib/protostar/message/field_info.rb`: the `open_enums:` flag (deviation 1); default false,
  behaviour unchanged. Test: `test/message/open_enums_test.rb` (3 runs: closed by default; open singular, repeated,
  packed, assignment, encode; open map values).
- `lib/protostar/json/parser.rb`: dropped `create_additions: false` from `::JSON.parse`. **Reason:** json 3.0 removed
  that keyword and raises `ArgumentError`, which the parser reports as a ParseError, so *every* JSON decode failed on
  any Ruby whose newest installed json is 3.x (it is 3.0.2 on this machine for 3.2.2, 3.4.1 and 4.0.0 outside bundler).
  `create_additions` defaults to false in every json version, so nothing else changes.
- `.standard.yml`: ignores the shim's generated `_pb.rb` files and Google's `test/google/`; the shim's own code is lint-clean.
- `Rakefile`: `shim:test` (bundle install if needed, then `rake generate:check test` in the shim with its own bundle).
- `.github/workflows/ci.yml`: `shim` job, Ruby 3.2/3.3/3.4/4.0, working directory `shims/google-protobuf`, own bundler cache, `fetch-depth: 0` (the Bundler test locks a git source at HEAD).
- `README.md`: a "Replacing google-protobuf" section with the github+glob form.

## Numbers

Same message (`BasicTest::TestMessage` with 7 fields set, 20 repeated ints), Ruby 3.4.1 interpreter, per operation:

| | shim | google-protobuf 4.36.2 (C) |
|---|---|---|
| `new` with 3 fields | 3.4 µs | 1.1 µs |
| 4 field reads | 0.35 µs | 0.6 µs |
| 2 field writes | 1.1 µs | 0.3 µs |
| encode | 15 µs | 0.25 µs |
| decode | 11 µs | 1.2 µs |
| encode_json / decode_json | 18 / 50 µs | 2 / 2 µs |
| `require "google/protobuf"` / `descriptor_pb` / `basic_test_pb` | 45 / 49 / 33 ms | 28 / 1 / 3 ms |

Encode is protostar's own cost (a native class encodes the same message in the same 14 µs); the shim adds a depth check
(0.7 µs) to report cycles and too-deep messages the way the gem does.

## Found along the way

- **protostar's encoder is slow on small repeated fields** (14 µs here; sizing alone 10 µs). WS3 territory.
- **Generated decoders and encoders warn under `ruby -w`** ("assigned but unused variable - values/start", dozens per
  loaded file). Users who run tests with warnings will see them for every class, native or shim. WS3's generators.
- The json 3.x breakage above affected native protostar as much as the shim.

## For WS9 (pbbuilder)

- pbbuilder's full suite already passes against the shim (35 runs). The calls it makes are pinned in
  `test/pbbuilder/pbbuilder_api_test.rb`; map fields' `subtype.msgclass` returns a real entry class.
- Its `set!` relies on `@message[name] ||= ...` returning nil for unset message fields, and on
  `RepeatedField#replace` accepting an Array (it now wants exactly an Array, as the C gem does).
- Open question: should WS9's native builder target `Protostar::Message` only, or both styles? The shim's classes are
  `Protostar::Message` subclasses, so a builder written against protostar's reflection (`__fields`, `__by_name`) works
  on both.

## For WS10 (release)

- The shim depends on protostar `= VERSION`: it uses protostar internals marked `@api private`
  (`Schema::Proto.build`, `HashCodec`, `Types::Definer#setup`, `Text::Extensions`, `Emitters::GoogleRuby.serialized`).
  Release both together, same version, or turn those into public API.
- rubygems.org's `google-protobuf` is Google's: this gem can only ship from git, a path, or a private source (README).
- License: the gem is MIT like protostar, but its `*_pb.rb` embed descriptors of Google's BSD-licensed `.proto`
  files; ship Google's LICENSE notice with the gem (not done: the shim has no LICENSE file yet).
- CI's shim job resolves grpc's platform gem fresh each run (the shim's `Gemfile.lock` is gitignored like the root's)
  and allocates a 2 GiB string in `encode_decode_test.rb` (Google's `test_decode_2gb_payload_without_crashing`).

## Open questions

1. Should protostar make `Types::Registry` accept a base class, so shim classes can be `AbstractMessage` subclasses
   as in the gem? Three lines in `types.rb`; not done to keep changes outside `shims/` minimal.
2. Should descriptor `inspect` follow the C gem (default `#<...:0x...>`) instead of the FFI's readable form?
3. JSON extensions are handled for the top-level message only; nested extension JSON would need protostar's JSON
   encoder/parser to know about extensions (WS3/WS5's open question of who owns extensions).
