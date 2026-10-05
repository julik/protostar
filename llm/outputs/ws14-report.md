# WS14 report: make it nice

`Protostar::Schema` objects are now the one representation. They are drafted directly by
the compiler, the DSL and `File.from_proto`, read directly by everything else, and
translated to protoc's `FileDescriptorProto` only at the edges (`to_proto`, `serialize`,
`from_proto`). No stage hands a descriptor-shaped Hash to the next. The six changes landed
in the spec's order, 19 commits, every suite green at each step. Nothing pushed or merged.

## What was built

| Change | Commits | What landed |
|---|---|---|
| 1. Construction API | `4f1b413`, `cc36fa3` | `Schema::File.draft` and the draft classes (`lib/protostar/schema/draft.rb`, `draft/resolution.rb`, `draft/copy.rb`): calls create the real descriptors at once; `link`, `resolve`, `freeze!` finish them. Map entries, synthetic oneofs, group fields and json names are made here; the naming rules (`Draft.map_entry_name`, `.synthetic_oneof_names`, `.group_field_name`, `Schema.json_name`) exist once and the parser calls them |
| 2. Options as objects | `545341f` | `Schema::Options` with one subclass per options message (`FieldOptions`, ...): a reader per field (and `?` for booleans), custom options keyed by extension `Field` (`extension(field_or_name)`), unknown fields as wire bytes, `features` resolved; `Schema::MessageValue` for message-typed values; `Features#extensions` keyed by `Field` |
| 3. Compiler produces Schema | `e961f59`, `3401673`, `9b7639f` | `build_file` drafts every element as it registers its symbol; the symbol table holds drafted descriptors; `cross_link` records resolutions on them; `OptionInterpreter` folds into `MessageValue`s set on the draft and reads option types from the linked draft (the structural build is gone); the validator reads `Linker#descriptor_of(node)`; retention stripping works on Schema and `Draft.copy`; `Linker::Problem`, `Linker::Pending`, `SymbolTable::Symbol`, `Lexer::Token` are classes; AST `to_h` moved to `test/support/ast_hash.rb` |
| 4. DSL and emitters | `becdba3`, `26a3c72`, `481172b` | `Protostar::DSL` is a set of adapters over the draft (spelling unchanged); the native emitter reads Schema objects (output byte-identical: bootstrap, examples and conformance checks pass without regenerating); RBS, gRPC and naming read option readers; options from `import option` files are emitted as unknown bytes |
| 5. Translation layer | `54a3901`, `574505d` | `lib/protostar/schema/proto.rb`: `to_proto` on every descriptor and on `Options`, `serialize`, `File.from_proto` (one pass, options decoded after linking), `MessageValue#encode`/`.decode` as the only place custom options are wire bytes; `Schema::Builder` and `HashCodec` deleted; tier A compares `to_proto.to_h` with the golden JSON read by protostar's JSON parser |
| 6. Naming and shape | `cfdb6b2`, `637b8f5`, `cd7f1d7`, `531a485` | `Klass.reflection` (`Message::Reflection`); `Message#visibility`/`Enum#visibility` answer `:local`/`:export`; `JSON::Path::MapKey` and `Text::Tokenizer::Token` are classes |
| Docs | `fb1c47d`, `d220736`, `2830722` | `docs/schema-api.md` (new); `docs/compiler-internals.md` sections 1, 2, 4, 5, 7 to 23 rewritten with every example re-run; CHANGELOG |

Also: `bench/compiler_bench.rb` (`588dba3`), the section 21 numbers plus the descriptor
loading paths, so before and after are measured the same way.

## Before and after: the representations removed

| Before | Where it travelled | After |
|---|---|---|
| The descriptor hash (`FileDescriptorProto#to_h` spelling) | `Linker#descriptor_hash` to `Schema::Builder.build`; `Schema::File#to_h` to emitters, retention, the shim, the corpus tests; `DSL::FileBuilder#to_h` to the builder; `HashCodec.decode` to the builder in `from_proto` | drafts; `to_proto`/`from_proto` at the edges; `to_h` is `to_proto.to_h`, read only |
| `Schema::Builder.build(hash, pool:)` (key checks, linking, features, defaults) | compiler, DSL, `from_proto`, 15 test files | `File.draft(...)`, `#resolve(pool)`, `#freeze!` |
| `Linker#structural_hash` and its extra `Builder.build` | option interpretation | the linked draft, resolved once without options |
| Options Hash: known fields by name, `:__extensions` by full name, `:__unknown_fields` as triples; `Options#[]` over it | validator, emitters, retention, features, shim, tests | `Options` subclasses with readers; extensions by `Field`; unknown fields as bytes; `MessageValue` for nested values |
| `features` as a raw Hash; `Features#merge(hash)`; custom features by name | feature resolution, validator | declared `FeatureSet` is a `MessageValue` (`options[:features]`); `options.features` resolved; custom features keyed by `Field` |
| `Schema::Proto::HashCodec` (hash to bytes and back, driven by Schema) | `serialize`, `to_proto`, `from_proto`, the Google-format emitter, the shim | `Proto::Writer` (Schema to bootstrap messages), `Proto::Reader` (messages to a draft), `MessageValue` codec for option values only |
| `Retention.strip(hash)` and a rebuild | `Compiler#output_file` | `Retention.strip(file, pool, types)` over options, then `Draft.copy` |
| `Compiler::WireEncoder` (folded hash to bytes, for `Any` in aggregates) | `TextFormat` | `MessageValue#encode` |
| `AST::*#to_h`; AST `resolved_type`, `resolved_extendee`, `resolved_input`, `resolved_output` | parser tests; linker to hash | `test/support/ast_hash.rb`; resolutions recorded on drafted descriptors |
| `Struct.new`: `Linker::Problem`, `Linker::Pending`, `SymbolTable::Symbol` (holding AST nodes for local symbols), `Lexer::Token`, `JSON::Path::MapKey`, `Text::Tokenizer::Token` | | frozen classes (Token stays mutable, as protoc's tokenizer reuses it); local symbols hold drafted descriptors |
| DSL hash building: `FileBuilder#to_h`, `DSL.map_entry_hash`, `field_hash`, `add_synthetic_oneofs`, `DSL.file_hash` | generated `_pb.rb` loading | adapters onto the draft |
| Synthesis rules in five places (parser, DSL twice, emitter's sugar check, `Builder.json_name` used by linker, validator, emitters) | | `Schema::Draft` and `Schema.json_name`; the parser and emitter call them |
| `GoldenHash`'s hand-written JSON conversion (reading descriptor.proto metadata from a golden) and `CompilerSupport.strip_extensions` | tier A, round trip, ruby corpus | `FileDescriptorSet.decode_json` (protostar's parser) and `to_proto.to_h`, which has no custom options to strip |
| The custom-options oracle sweep's own JSON printer for option hashes | oracle | the C gem decodes our options bytes and the golden's |
| `:VISIBILITY_LOCAL`/`:VISIBILITY_EXPORT` from Schema readers | linker, validator | `:local`/`:export` |
| Message reflection only through `__fields`, `__by_name`, `__set`, `__get` | | `Klass.reflection`; the `__` names stay private fast paths |

## Tests

| Suite | Before | After |
|---|---|---|
| `bundle exec rake`, Ruby 3.4.1 | 2,330 runs, 99,480 assertions, 0 failures, 335 skips | 2,345 runs, 99,870 assertions, 0 failures, 335 skips (same skips); standard clean |
| `bundle exec rake`, Ruby 3.2.2 | same | 2,345 runs, 0 failures, 335 skips |
| `bundle exec rake`, ruby-4.0.0 | same | 2,345 runs, 0 failures, 335 skips |
| oracle (`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`) | 2,330 runs, 245,637 assertions, 0 skips | 2,345 runs, 246,026 assertions, 0 failures, 0 skips |
| compiler tests alone (oracle) | 759 runs, 127,486 assertions, 21 s | 759 runs, 127,486 assertions, 17.7 s |
| `rake test:warnings` | clean | clean ("No warnings from lib/") |
| `rake shim:test` | 997 tests, 0 failures, 45 omissions | 997 tests, 0 failures, 45 omissions |
| `rake conformance:run` | 5,648 + 1 expected failure; text 909 | 5,648 + 1 expected failure; text 909 |
| `bootstrap:check`, `examples:check`, `conformance:check`, `rbs:validate` | pass | pass, no generated file regenerated |
| pbbuilder (`shim:pbbuilder`, `builder:pbbuilder`), Rails 7.2, 8.0, 8.1 | 35 runs, 1 skip each | 35 runs, 75 assertions, 0 failures, 1 skip each, both variants |

The acceptance tests are untouched in what they check: corpus tiers A and B, the 239 parser
cases and 28 source-info cases, the 116 validation snippets, the 107 descriptor-set byte
comparisons, the Google-format, RBS and gRPC goldens, conformance, Google's tests through
the shim, pbbuilder, the examples. Tier A now compares through the translation layer, as
the spec asks; it found nothing to fix.

New: `test/schema/draft_test.rb` (7: the spec's example and a proto2 and an editions file
drafted by hand serialize to exactly the compiler's bytes; synthetic oneof naming; lookups
before freezing; errors; naming rules), `test/schema/options_test.rb` (4: readers,
extensions by field and name, unknown bytes, resolved features, `declared?`, reader set
pinned to descriptor.proto's fields, `MessageValue#merge`), `test/schema/from_proto_test.rb`
(11, the facts of the deleted `builder_test.rb` that still apply, through `from_proto`),
`test/message/reflection_test.rb` (4), an emitter test for `import option` extensions, and a
`default_json_names:` test. Rewritten to assert the same facts through the new API:
`golden_round_trip_test` (every `.binpb` through `from_proto` back to the same bytes, and to
the golden JSON), `features_test` (custom features declared by a drafted extension),
`bootstrap/proto_test`, the fixtures that were hashes (now drafts, or `FileDescriptorProto`
messages read through `from_proto`), `ruby_corpus_test` (bytes instead of hashes). Deleted:
`test/schema/builder_test.rb`.

## Performance

`bench/compiler_bench.rb`, Ruby 3.4.1 interpreter, best of 10 (3 for the corpus); "before"
is the same bench on `c97b431` the same day. Full table in `docs/compiler-internals.md`
section 21.

| What | Before | After | |
|---|---|---|---|
| Lex `unittest.proto` | 15.6 ms | 15.3 ms | |
| Parse it | 27.7 ms | 26.2 ms | |
| Link it, imports pooled | 42.4 ms | 31.3 ms | -26% |
| Validate it | 9.0 ms | 8.7 ms | |
| `compile` it, imports pooled | 104.9 ms | 85.3 ms | -19% |
| `compile` it, fresh `Compiler` | 136.6 ms | 114.0 ms | -17% |
| the same, `retain_options: true` | 118.2 ms | 96.2 ms | -19% |
| the same, `source_info: true` | 211.4 ms | 144.8 ms | -32% |
| `descriptor.proto`, fresh `Compiler` | 30.4 ms | 26.6 ms | -13% |
| Whole corpus, 107 files | 5.10 s | 3.95 s | -23% |
| Whole corpus, `source_info: true` | 6.48 s | 4.65 s | -28% |
| Emit native Ruby (4 files) | 12.4 ms | 11.0 ms | |
| Load that Ruby through the DSL | 18.9 ms | 20.5 ms | +8% |
| `add_serialized_file` (4 files) | 33.2 ms | 20.7 ms | -38% |
| `to_proto` with source info | 49.8 ms | 32.1 ms | -36% |
| `serialize` with source info | 34.9 ms | 21.8 ms | -38% |
| `serialize` without source info | 9.9 ms | 9.6 ms | |
| `bench/codec_bench.rb` (decode, frozen decode, encode, small decode, small encode) | 40.7, 54.2, 28.2, 5.03, 5.44 µs | 40.6, 53.6, 27.6, 4.96, 5.27 µs | unchanged |

Where the gains come from: the structural build and the hash checks are gone, names are
resolved once, `source_info` locations become frozen objects once instead of hashes built
and rebuilt, `from_proto` decodes options once after linking instead of decoding the file
twice, and the stripped copy is copied from Schema objects. The one loss is loading
generated Ruby, +8%: every descriptor now carries an options object bound to its features
(interned when empty), and the DSL adds an adapter call per element. Before tuning it was
+18%; explicit keywords in place of splats, hash lookups for type checks, interning without
Array keys and a memoised `Features#hash` brought it down. `serialize` with source info was
+33% when it encoded 5,850 `Location` messages; it now writes them straight to bytes.

## What resisted, and why

1. **Options do not wrap the bootstrap's option messages.** The spec suggested
   `Options` wrap `Protostar::Google::Protobuf::FieldOptions`. `descriptor_pb.rb` defines
   that class by loading descriptor.proto through the DSL, and descriptor.proto's own
   fields carry options (`packed`, `retention`, `edition_defaults`) feature resolution needs
   before the class exists; map entries alone (`map_entry: true`) would make nearly every
   generated file load `descriptor_pb.rb` (about 49 ms) at require time; and custom options
   of message types have no class at all. `Options#to_proto` gives the real message.
2. **The parser still expands maps, groups and proto3 `optional`.** protoc's parser does,
   and the 90 `parser_unittest.cc` parse cases pin that pre-link tree (with the entry
   messages and synthetic oneofs in it); several validator messages ("Expanded map entry type
   X conflicts...") inspect it. Moving the expansion to the linker would mean synthesising
   again in test support to compare with protoc. The rules are the draft's; the parser calls
   them.
3. **The DSL's text spelling is unchanged.** Nested custom options stay `__extensions:`,
   unknown fields `__unknown_fields:` triples, and the emitter keeps writing
   `visibility: :VISIBILITY_EXPORT`, because changing what the emitter writes would mean
   regenerating committed generated files (bootstrap, examples, conformance), which the
   checks treat as acceptance artifacts. The DSL reads `:local`/`:export` too.
4. **The AST keeps protoc's enum names** (`:LABEL_OPTIONAL`, `:TYPE_INT32`,
   `:VISIBILITY_LOCAL`). It is the parser's pre-link `FileDescriptorProto`, private, and the
   ported checks read those names; the linker translates at the drafting boundary.
5. **`options.features` is the resolved set**, as the spec asks, which makes it the one
   reader that does not answer what was declared (`options[:features]` does). Argued in
   `docs/schema-api.md`.
6. **Option readers do not apply descriptor.proto's defaults.** `packed` unset and `packed`
   false differ for feature inference and for `to_proto`, so a reader answers what was
   declared, nil when not.
7. **Compiler-only hooks on the draft** (`__seal`, `__resolve_type`, `__resolve_extendee`,
   `__resolve_rpc`) and `Descriptor#__link` remain `@api private`: the compiler resolves
   names with protoc's symbol table and diagnostics, which the draft should not grow.
8. **`compile_to_hashes` stays** (WS2 public API), now `compile(...).map(&:to_h)`, documented
   as a reading projection.
9. **`Text::Tokenizer::Token` and `JSON::Path::MapKey` take positional arguments**: three
   and one obvious arguments, built per token and per map key in hot loops.

## Behaviour that changed

- The DSL resolves custom option names when a file loads; a name that resolves nowhere is a
  `Schema::Error` (it used to be kept by name). To keep generated files loading on their
  own, the native emitter writes options whose extension the file reaches only through
  `import option` as unknown bytes, as protoc's Ruby generator does. Generated text changes
  only for such files; no committed generated file has one.
- `to_h` on a descriptor no longer contains custom options (they are bytes in `to_proto`).
- `to_proto(pool:)` and `serialize(pool:)` lost `pool:`: options hold their extensions.
  `to_proto`/`serialize` gained `default_json_names:`.
- `DSL.file_hash` and `DSL.map_entry_hash` are gone (the hash they built is not the model);
  `DSL.file(..., registry: nil)` builds a file without defining classes.
- `Schema::Builder` is gone: `Schema::File.draft`, `Schema::File.from_proto`,
  `Schema.json_name`.

Public API of WS3 to WS9 is unchanged apart from these, and the shim's public API is
untouched (its internals moved from `HashCodec` to `to_proto`/`from_proto`).

## For the next workstreams

- Build descriptors with `Schema::File.draft` (`docs/schema-api.md`). To build from protoc's
  bytes, `Schema::File.from_proto`; to copy a file into another pool, `Schema::Draft.copy`.
- Read options through readers and `extension(...)`; never through a hash. `options.features`
  is resolved; `options[:features]` is what was declared.
- To compare two files across pools, compare `serialize` bytes: extensions are keyed by
  descriptor, and descriptors are compared by identity.
- `Klass.reflection` is the public way to walk a message's fields.

## Open questions

1. Should the DSL's spelling move to `visibility: :local` and `extensions:` inside nested
   values, with one regeneration of the committed generated files?
2. Should option readers answer descriptor.proto's defaults, as protobuf message getters
   do, with `set?` for presence?
3. Should `Schema::Field` keep whether `json_name` was explicit? The Google-format emitter
   and the shim still treat a json_name equal to the derived one as unset (WS4 deviation 4).
4. Should views (`Protostar::View`) get a reflection object too?
5. Should `compile_to_hashes` be deprecated now that it is only a projection?
