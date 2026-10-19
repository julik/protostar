# WS16: Sorbet RBI next to RBS

Branch `ws16-rbi-out`. Suite 2510 runs, 0 failures (338 skips without Sorbet, 336 with it).
`rake` (test + standard), `rake test:warnings`, `rake rbs:validate`, `rake yard`,
`bootstrap:check`, `conformance:check` and `examples:check` are green.

## What was built

- **`Emitters::FieldTypes`** (`lib/protostar/compiler/emitters/field_types.rb`): the type of
  every field's reader, writer and `new` keyword, decided once and spelled by a dialect, RBS
  or Sorbet. `ProtostarRbs` now uses it (its output is byte for byte what it was; the
  bootstrap `sig/` is unchanged), `ProtostarRbi` and `Rbi` use it, and protoc's `Rbs` uses it
  for single values (its 4-parameter `Map[...]`/`RepeatedField[...]` stay protoc's; all
  protoc RBS goldens still match).
- **`Emitters::ProtostarRbi`**: `# typed: strict` RBI for protostar's classes. A class per
  message `< ::Protostar::Message` (nested as nested classes, map entries skipped), a module
  per enum extending `::Protostar::Enum` with `CONST = ::T.let(n, ::Integer)`, readers and
  writers typed as the RBS has them (writers take what `Message::Coercion` accepts: Hashes for
  messages, `Time` for Timestamp, `Numeric` for Duration, Integer for float fields, nil to
  clear), `initialize(fields = nil, **keywords)`, `has_`/`clear_`, `which_<oneof>`, the
  well-known mixins. Names Ruby cannot take as keywords (`Fields`, `Field_name17__`) fall into
  `**rest: T.untyped`, as tapioca does; `BEGIN`/`END` enum constants are assigned from outside
  the module. Every type is spelled from the root (`::T.any`, `::String`) since a message may be
  called `T` or `String`. Accessors skip the names `Message` already has, exactly as the
  runtime does.
- **`Emitters::Rbi`**: RBI for google-protobuf's classes (protoc's `_pb.rb`, run by the C gem
  or the shim), in tapioca's shape: `< ::Google::Protobuf::AbstractMessage`,
  `RepeatedField[T]`, `Map[K, V]`, keywords for `new`, `_as_value` for wrappers, `_const` for
  enums, oneof readers returning `T.nilable(Symbol)` (checked against the C gem; protoc's RBS
  says the union of the field types, which is wrong), and `decode`/`encode`/`decode_json`/
  `encode_json`/`descriptor` declared on each class with its own type.
- **CLI**: `--rbi_out=DIR`, `--no-rbs`, `--no-rbi`. Next to `--ruby_out` (without
  `--google_out`) the `.rbs` and `.rbi` go beside the `.rb` unless declined or redirected;
  `--rbs_out`/`--rbi_out` with `--no-*` is an error. `--google_out` writes exactly what protoc
  writes. One file to stdout prints only Ruby. `--rbi_out` alone or with `--google_out` writes
  the google-format RBI (editions files included; only protoc's RBS refuses them).
- **Plugin**: outputs `rbi`, and `no-rbs`/`no-rbi`; `ruby` brings `rbs` and `rbi` along.
- **`rbi/protostar.rbi`** (shipped; `rbi/**/*.rbi` added to the gemspec, so `tapioca gem`
  exports it): `Message` class and instance API (`decode` etc. return `T.attached_class`),
  `Reflection`, `View`, `Enum`, `Types`, `JSON`, `Text`, `Builder`, errors, `UnknownField`,
  the `WellKnown` mixins, the short WKT aliases, and the basics of `Schema` (`File`,
  `Message`, `Field`, `Oneof`, `Enum`, `EnumValue`, `Service`, `Pool`). The same Schema
  section was added to `sig/protostar.rbs`, and `descriptor` now returns `Schema::Message` /
  `Schema::Enum` there instead of `untyped`. Defaults are `T.unsafe(nil)`, as tapioca writes
  them, so the RBI never states a wrong default.
- **WKT RBI**: `script/bootstrap.rb` writes `rbi/protostar/google/protobuf/*_pb.rbi` with the
  new emitter; `rake bootstrap:check` covers them.
- **rbs-by-default** (`llm/todos/rbs-by-default.md`) is done by the same change; marked so.
- Examples regenerate with their `.rbs` and `.rbi` committed (`script/examples.rb` globs all
  three), and playbook 01's README says what the two files are.

## Decisions

**RBI default-on.** Kept, as the user's direction for sidecars. For a non-Sorbet user it is
one more file per proto, removable with `--no-rbi`, at no runtime cost. For a Sorbet user it
is necessary: the `_pb.rb` is `typed: ignore` (below), so without the RBI the constants do not
exist for Sorbet. Making it opt-in would have meant either a conditional sigil or broken
constants for anyone who forgot the flag.

**The sigil is always there.** Every native `_pb.rb` now starts
`# frozen_string_literal: true` / `# typed: ignore`. I checked the alternatives with Sorbet
0.6.13573: a file with no sigil (`typed: false`) still gets the two 4022 errors ("Cannot
initialize the class by constant assignment"), so leaving it out never gives a clean run;
writing the sigil only when an RBI is written would make the `.rb` depend on flags and
differ between `--ruby_out` and stdout. Always-ignore needs no `sorbet/config`, and the RBI is
the type source. Cost: a Sorbet user who passes `--no-rbi` sees "Unable to resolve constant"
where they would have seen 4022 errors. Bootstrap, conformance and example files are
regenerated; their checks pass.

**Runtime RBI is hand-written, kept in step by a test**, not generated from the RBS: the RBS
uses interfaces, overloads and generic methods that have no mechanical Sorbet spelling.
`test/rbi/runtime_rbi_test.rb` parses `sig/protostar.rbs` with the rbs gem and the RBI with
Prism and requires the same constants and the same `Class#method` / `Class.method` lists
(verified to fail on a renamed method). It skips on Ruby 3.2, which has no Prism.

**Google-format types follow tapioca**, so an app can switch between `tapioca dsl` and
`--rbi_out` without changing its signatures. `RepeatedField`/`Map` type members are not
declared by us: tapioca's DSL pass declares them, and declaring them in a shipped RBI would
clash with it. The tests use `test/fixtures/sorbet/google_protobuf.rbi` as a stand-in.

## Tests

- `test/emitters/rbi_test.rb`: pinned native RBI for a file with nested types, an enum with a
  comment and an `END` value, map, repeated, optional, oneof, Timestamp, a wrapper, a field
  named like a Message method and one that cannot be a keyword; the RBI's methods equal the
  class's public methods; google-format slices; empty files; bootstrap namespaces; every
  corpus file in both formats parses with Prism; **every corpus file through
  `sorbet --no-config` with zero errors** (98 native files in 3 batches with the runtime RBI;
  the google format, well-known types included, with the stub); and an app fixture
  (`test/fixtures/sorbet/app.rb` + `shop.proto`, compiled through `Protostar::CLI`) where
  Sorbet reports exactly three things: the revealed type `Shop::Order` from `decode`, the typo
  `custmer_email`, and an Integer written to a String field.
- Sorbet comes from `SORBET=path` or the optional Gemfile group (`BUNDLE_WITH=sorbet`, gem
  `sorbet-static`); without it those two tests skip. I ran them with sorbet-static 0.6.13573.
- CLI and plugin: sidecars by default, `--no-rbs`/`--no-rbi`, redirection, the contradiction
  error, google output unchanged, plugin `no-*` and `google,rbi`.
- `test/support/signature_batches.rb` holds the corpus batching the RBS test had inline; both
  tests use it.

## Tapioca

tapioca 0.20.0's protobuf DSL compiler, run against the shim on a google-format `_pb.rb`
(scratch project, tapioca not added to the bundle):

- Out of the box it writes RBI for the **enums** and for `RepeatedField`/`Map`, and **misses
  every message**. Its `gather_constants` takes the descendants of
  `Google::Protobuf::AbstractMessage` when that constant is defined; the shim defines it
  (private, as the C gem does) but its message classes subclass `Protostar::Message`.
- With `gather_constants` pointed at classes extending `Google::Protobuf::MessageExts::ClassMethods`
  (a 10-line override in `sorbet/tapioca/compilers/`), it writes the messages' RBI and its own
  check finds no errors: the descriptor API it reflects on (`each_oneof`, `subtype`,
  `has_presence?`, `msgclass`, `enummodule`, map detection by `new(field: {})`) works on the
  shim.
- Fixing it for good belongs to the shim (message classes would need `AbstractMessage` among
  their ancestors, or `AbstractMessage` must not be defined); I left the shim alone, as the
  brief asked. docs/migration.md describes both routes.

protoc-format `_pb.rb` files still need `--ignore` in `sorbet/config` with either route (4022
errors otherwise), as tapioca's own docs say; README and migration.md say so.

### Follow-up: messages descend from AbstractMessage

The C gem 4.36.2 has `Timestamp.ancestors` = `[Timestamp, AbstractMessage, MessageExts,
Object, ...]` with `AbstractMessage` a private constant; tapioca reaches it through
`const_defined?`/`const_get` and collects `ObjectSpace.each_object(AbstractMessage.singleton_class)`.
The shim now has the same shape: `AbstractMessage < Protostar::Message`, private, including
`MessageExts`, and the shim pool's registry is `Registry.new(open_enums: true, base:
AbstractMessage)` (new `base:` option, default `Protostar::Message`, so native classes are
unchanged). Map entry classes made on request subclass it too.

- `tapioca dsl --only=Protobuf` in a scratch project (the `shop.proto` above, shim via
  `protostar/google_protobuf_shim`, no override) creates `shop/order.rbi`,
  `shop/line_item.rbi`, `shop/status.rbi`, `google/protobuf/timestamp.rbi`,
  `repeated_field.rbi`, `map.rbi`; "No errors found". `srb tc` with `lib/shop_pb.rb` ignored
  and a stand-in `google_protobuf.rbi`: no errors; an app file gets the revealed types and
  catches an unknown method and a wrong setter type.
- Tests: `pools_test.rb` checks the descendants as tapioca gathers them (shim classes,
  well-known types and a map entry in; native classes and `Protostar::Message` out);
  `types_test.rb` checks `base:`. Four new differential probes (const_defined?, superclass
  names, the ObjectSpace walk, `AbstractMessage.include?(MessageExts)`) match the C gem.

## Not done, open

- No RBI for gRPC `_services_pb.rb` (optional in the brief).
- `Builder` sets fields through `method_missing` (`pb.name "x"`), which Sorbet cannot see;
  `set!` is typed. The RBI says so.
- `rbi/protostar.rbi` reopens `class IO; class Buffer; end; end` because Sorbet's stdlib RBI
  lacks `IO::Buffer`.
- CI does not install `sorbet-static`, so the Sorbet tests skip there unless `BUNDLE_WITH=sorbet`
  is added to a job.
- For WS15: regenerated files (`lib/protostar/google/protobuf/*_pb.rb`,
  `conformance/generated/**`) gained the sigil line; on a conflict, regenerate. The RBI's
  accessor list comes from `Message::Accessors.reserved`, like the RBS; a test compares it
  with the class's methods, so a change in accessor rules shows up there.
