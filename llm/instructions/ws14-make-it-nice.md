# WS14: make it nice

The "make it work" phase is over: every corpus file compiles to protoc's exact descriptor,
every golden matches byte for byte, the conformance suite passes, the shim runs Google's
own tests. Now the internals get to be good Ruby. The brief from Julik:

> We should not be following the internal representation of protoc output, hashes and all
> and the incredibly ugly structs, just to match it. We can have a translation layer from
> our thing to what protoc would be producing, to compare, but we can do better.

Read `docs/compiler-internals.md` first: it describes the current design honestly,
including the parts this workstream replaces. Then the WS1, WS2, WS4 and WS6 reports for
the pieces that consume the current shapes.

## What "our thing" is

`Protostar::Schema` objects are the one representation. They are built directly, read
directly, and nothing in protostar passes a `FileDescriptorProto`-shaped Hash around as a
working value. The protoc shape exists only at the edges, as a translation:

- **in**: bytes of a `FileDescriptorProto` or `FileDescriptorSet` (the shim's
  `add_serialized_file`, `load_descriptor_set`, the protoc plugin) are decoded with the
  bootstrap classes and translated into Schema objects;
- **out**: `Schema::File#to_proto` produces the `FileDescriptorProto` message for descriptor
  sets, Google-format emission and `to_proto` on the shim's descriptors;
- **compare**: the corpus tests translate our Schema to protoc's shape (via `to_proto`
  and the JSON mapping) and compare with the goldens. Equality with protoc stays the
  acceptance test for every stage; it just stops being the data model.

`to_h` may survive as a debugging projection of `to_proto`, but no code path builds from
it or hands it to another stage.

## What changes, in order

1. **A construction API for Schema.** Today `Schema::Builder.build(hash, pool:)` is the
   only way to make descriptors, and the compiler, the DSL and `from_proto` all contort
   themselves into producing that hash. Replace it with a mutable draft stage that reads
   like Ruby: something in the spirit of

   ```ruby
   file = Schema::File.draft("shop.proto", package: "shop", syntax: :proto3)
   item = file.message("Item") do |m|
     m.field "name", 1, :string
     m.field "price_cents", 2, :int64, optional: true          # proto3 optional, synthetic oneof made here
     m.map "stock", 3, key: :string, value: :int32              # entry message made here
   end
   file.resolve(pool)    # link names, resolve features, validate shape
   file.freeze!          # deep freeze, Ractor-shareable, returns the Schema::File
   ```

   Decide the exact spelling; the test is that the compiler's linker, the generated-code
   DSL (`Protostar::DSL`) and the `from_proto` translation all become thin callers of it,
   with synthesis (map entries, synthetic oneofs, group field names, json names) done once,
   here, instead of three times. The frozen `Schema::File` and its API stay as WS1 defined
   them, so the codec, views, JSON, text, emitters and the shim keep working; extend them
   where the new model makes a reader obviously better, and list each such change.

2. **Options as objects.** `:__extensions` and `:__unknown_fields` keys inside a Hash were
   a stopgap from before the bootstrap existed. Now `Schema::Options` wraps the real option
   message (`Protostar::Google::Protobuf::FieldOptions` and friends): known options are
   readers (`options.deprecated?`, `options.java_package`, `options.packed`), custom
   options are reached by the extension's descriptor or full name
   (`options.extension("acme.limits")`, `options.extensions` as a frozen Hash keyed by
   `Schema::Field`), unknown bytes stay available, `features` is the resolved
   `Schema::Features`. The compiler interprets options straight into this model. The wire
   form of custom options (extension bytes inside the options message) is produced by
   `to_proto` and read by the `from_proto` translation, nowhere else.

3. **The compiler produces Schema directly.** `Linker` stops assembling a descriptor hash
   and instead drives the draft API: `build_file` creates draft messages, fields, enums,
   services; `cross_link` resolves on them; `OptionInterpreter` writes `Options` objects;
   `Validator` reads the drafted or frozen file. `Linker::Problem`, `Linker::Pending`,
   `Lexer::Token` and any other `Struct.new` that stands in for a real class become small
   classes with keyword constructors and intention-revealing methods. `AST` nodes lose
   `to_h` as a working interface; if the parser tests need protoc's pre-link shape, derive
   it in the test support, not in the AST. Diagnostics, error ordering and recovery stay
   protoc-identical; those are behaviour, not representation.

4. **The DSL and the emitters.** `Protostar::DSL.file` drives the draft API instead of
   building a hash. The native emitter reads Schema objects, not `file.to_h`. The
   Google-format, RBS, gRPC and descriptor-set emitters read Schema objects and only the
   descriptor-set one calls `to_proto`.

5. **The translation layer.** `lib/protostar/schema/proto.rb` becomes the one place that
   knows protoc's shape: `Schema::File#to_proto`, `Schema::File.from_proto(message, pool:)`,
   and the JSON-mapping helpers the corpus tests use. The `GoldenHash` test support and
   the tier A and tier B tests compare through it. Byte-for-byte descriptor-set goldens
   stay the proof that the translation is exact.

6. **Naming and shape pass over the rest.** With the above in place, walk `lib/` once for
   the same smell elsewhere: `__`-prefixed reflection on message classes (`__fields`,
   `__to_h`, `__set`) gets a proper, documented reflection object (`Klass.reflection` or
   similar, chosen so it cannot clash with field accessors) while the `__` names stay as
   private fast paths for the generated code; descriptor-shaped Symbols that leak into
   public readers (`:LABEL_OPTIONAL` where `:optional` is meant) are normalised; any
   remaining `Struct.new` that should be a class becomes one. Do not rename public API
   that WS3 to WS9 established without a reason stated in the report.

## What must not change

- Every existing test keeps passing or is updated only where it asserted an internal
  shape that this workstream removes; the acceptance tests (corpus tiers, parser cases,
  validation snippets, descriptor-set bytes, Google-format and RBS and gRPC goldens,
  conformance, Google's Ruby tests via `rake shim:test`, pbbuilder's suite, the examples)
  are untouched and green.
- Ractor shareability of every built descriptor and class.
- Performance within 10% of the current numbers in `docs/compiler-internals.md` section 21
  and `bench/`; the stripped-copy and structural-build duplication noted there may well
  disappear, which would be a gain to report.

## Deliverables

The refactor itself; `docs/compiler-internals.md` updated section by section to describe
the new design (keep its honesty and its real outputs; re-run every example); a short
`docs/schema-api.md` showing the draft API, the options API and the reflection API with
examples; `llm/outputs/ws14-report.md` with a before-and-after map of the representations
that were removed, the performance table, and anything that resisted the cleanup with the
reason.

## Out of scope

New features, extensions as first-class fields, the lazy readers, the shim's public API.
