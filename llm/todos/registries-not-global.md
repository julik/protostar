# Registries that are not process-global

**Status:** feature lead from Julik, 2026-10-06. Not scheduled. Touches the generated-file
format, so it wants doing before 0.2.0 rather than after.

> I do like `Protostar::DSL.message("acme.Person")`, but it is process-global, a global
> registry. We should find a better approach: say a `Rails.application.config.protobufs`
> registry storage where our registry can be stored, shareable between Ractors. Stuffing it
> into the global namespace is useful but should not be a required step nor the default.

## Today

- `Protostar::DSL.file` builds into `Protostar.generated_pool` and `Types.registry` by
  default; both are process-wide singletons. `Types::Registry` is Mutex-guarded and meant
  for the main Ractor; the classes it hands out are shareable, the registry itself is not.
- A generated file ends with constant assignments through the same globals:
  ```ruby
  module Shop
    Order = Protostar::DSL.message("shop.Order")
  end
  ```
  So loading a generated file does three things at once: registers the schema globally,
  defines classes globally, and names them as constants. None of the three is separable.
- `DSL.file(pool:, registry:)`, `Types.define(file, registry:)` and `Types::Registry.new`
  exist, so a private registry is possible by hand; the shim uses one. The DSL's
  `message(full_name)` lookup, `Types.find`, `Any` resolution in JSON and text, and the
  conformance testee all default to the global one.

## Wanted

**A registry is an object you hold.** `Protostar::Registry` (fold `Schema::Pool` and
`Types::Registry` into one thing with one lifecycle; a pool of descriptors and the classes
made from them belong together) that an application creates, fills and keeps wherever it
likes: `Rails.application.config.protobufs = Protostar::Registry.load("app/protos")`, a
constant, an instance variable of a service object. Several registries in one process, for
different schema sets or versions, are normal.

**Shareable between Ractors.** A registry that is finished is frozen and shareable:
`registry.freeze` (or `Registry.load(...)` returning one already frozen) makes every
descriptor, class, enum module and lookup table shareable, so a Ractor worker receives the
registry and resolves `"acme.Person"` without the main Ractor. Mutation after freezing
raises. Before freezing it is Mutex-guarded as today. Classes are already shareable; the
Mutex and the growing Hash are what stop the registry itself.

**Generated files stop touching globals.** A generated file becomes a description that a
registry *loads*, not code that registers itself at `require` time:

```ruby
# acme/person_pb.rb (generated)
Protostar::DSL.file("acme/person.proto", package: "acme", syntax: :proto3) do |f|
  ...
end
```

and nothing else: no `module Acme; Person = ...; end`. The DSL block returns a
`Schema::File` draft description; `registry.load("acme/person_pb.rb")` (or
`registry.add(file)`) resolves it against the registry's own pool, defines its classes in
that registry, and returns them. Imports resolve inside the registry, so loading
`person_pb.rb` pulls `google/protobuf/timestamp_pb` into the same registry, from the
bootstrap, the way `require` does today.

**Constants are opt-in.** `registry.assign_constants(under: Acme)` or
`Registry.load("app/protos", constants: true)` does what the generated constants block
does today, using protoc's naming rules, and is what most apps will call once at boot. The
global `Protostar.registry` stays as a convenience (`Protostar::DSL.message("acme.Person")`
keeps working against it), but nothing requires it and the generated files do not use it.

**Lookups take a registry.** `Types.find`, `Any#unpack`, `decode_json`'s `Any` resolution,
`Text.parse`, `Builder`, the conformance testee and the shim all take `registry:` already
or will; the default is the one the class was defined in (`Klass.registry`, from the
introspection brief), falling back to the global.

**The shim** keeps its own registry, which it already does; it becomes just another
`Protostar::Registry` behind `Google::Protobuf::DescriptorPool.generated_pool`.

## Migration

- The emitter writes the new file shape behind `--registry` for one release, then by
  default; the old self-registering shape keeps loading with a deprecation warning that
  names `Registry.load`.
- `Protostar.generated_pool` and `Types.registry` become aliases of `Protostar.registry`,
  deprecated, removed in 0.3.
- The examples and the README move to `Registry.load` with constants on, so the one-liner
  stays one line.

## Open questions

- Should `Registry.load` take a directory and glob `**/*_pb.rb`, or a list of files, or
  both? Both, probably, with dependency order worked out from the files' imports.
- Should a registry be able to load `.proto` sources directly, compiling in memory
  (`Registry.compile("app/protos")`)? Cheap to add on top of the compiler; a boot-time
  cost of about 1 ms per file. Worth it for development mode.
- Should two registries be able to share the bootstrap (descriptor.proto and the
  well-known types) rather than each define 160 classes? A frozen "parent" registry that a
  child resolves against would do it and would halve class-definition time for most apps.

## Tests

Two registries in one process with the same `.proto` and different constants; a frozen
registry crossing into a Ractor and resolving a name there; a generated file loaded into a
private registry with no global side effects (assert the global stays empty); the
deprecation paths; the shim on the unified class.

## Effort

Medium: the registry object itself is a merge of two existing classes; the generated-file
change and the deprecation window are most of the care.
