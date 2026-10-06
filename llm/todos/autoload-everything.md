# Autoload everything: pay only for what you use

**Status:** feature lead from Julik, 2026-10-06. Small-to-medium, not scheduled. Pairs with
`registries-not-global.md` (a frozen parent registry for the bootstrap) and the class-definition
row of `pure-ruby-codec-go-brrr.md`.

## Today (measured on main, Ruby 3.4, warm disk cache)

`require "protostar"` is 18 `require_relative`s that pull in everything:

| | |
| --- | --- |
| Time for `require "protostar"` | 82.5 ms |
| Files loaded | 85 under `lib/protostar/` (94 in all) |
| Of which the compiler | 18 files, about 6,200 lines |
| Of which JSON, text, views, builder, well-known mixins | 20 files |
| Of which the codec path a decode needs (schema, wire, message, codec, types) | about 35 files |

The one autoload that exists is for the short well-known-type names (WS13), which is why
`require "protostar"` does not load the 12 bootstrap `_pb.rb` files. Everything else is
eager. A Rails app that only decodes messages in a request pays for the compiler, the
text-format parser and the emitters at boot, and so does every generated `_pb.rb` file,
since it starts with `require "protostar"`.

## Wanted

`require "protostar"` loads the namespace and nothing it does not need yet; each part
arrives on first use through `autoload`, which is Ractor-safe and thread-safe in Ruby 3.x
and costs one Hash lookup per constant on first reference:

- `Protostar::Compiler` (and `Compiler::*`), `Emitters`, `CLI`, `Plugin`: only the CLI,
  the plugin, the Rake helper and `Registry.compile` need them. A process that loads
  generated files never does.
- `Protostar::JSON`, `Text`, `View`, `Builder`, `WellKnown`: on first use. `Message#to_json`
  and friends stay defined on `Message` as one-line delegations that trigger the autoload.
- `Protostar::Schema::Proto` (`to_proto`, `from_proto`, `serialize`): the translation layer
  and the bootstrap `descriptor_pb` it needs are only loaded when someone translates.
- Inside the compiler: lexer and parser are needed together, but the emitters, the
  validator's CLI-only checks, retention stripping and `TextFormat` (aggregate options)
  can each wait for their first call.
- Inside the codec: `DecodeGenerator` and `EncodeGenerator` are needed at define time,
  the sizer at first encode; `Wire::IOSource` only when an `IO::Buffer` shows up.
- The shim: `well_known_types`, `descriptor_pb` and each WKT `_pb.rb` on first reference,
  matching how the C gem's files are required one by one.
- `require "protostar"` itself should settle under 10 ms and leave the codec path at
  roughly its own cost; a decode-only process should never see `Compiler` in
  `$LOADED_FEATURES`.

## Rules, so autoload does not become a trap

- One `autoload` per constant, declared next to the namespace that owns it, with the file
  path spelled out; no `const_missing` tricks, no requiring from inside methods.
- Anything referenced in a hot path (the generated codecs, `Message#initialize`) is
  resolved once at define time, not on every call; autoload's cost is at first touch only,
  but a constant lookup in a loop that keeps missing would be wrong anyway.
- Ractors: an autoload triggered inside a non-main Ractor raises (`require` is main-only
  since 3.0). Every constant a Ractor worker could touch must be loaded before the Ractor
  starts, which means `Protostar.eager_load!` exists (like Zeitwerk's) and the Ractor
  documentation says to call it; the Ractor tests call it; and `Types.define` resolves the
  autoloads its classes depend on at define time so that classes defined on the main
  Ractor work in others without further loading.
- `Protostar.eager_load!` also serves apps that prefer boot cost over first-request cost
  (Rails production with `config.eager_load = true` calls it from a tiny Railtie or the
  app's initializer; no Railtie is shipped unless something else needs one).
- The test suite gets a test that `require "protostar"` alone loads no file under
  `compiler/`, `json/`, `text/`, `view/` or `builder.rb`, and one that `eager_load!`
  loads every file under `lib/protostar/` (so a new file cannot be forgotten).
- The bootstrap `_pb.rb` files already autoload through the short names; keep the long
  `Protostar::Google::Protobuf::*` names working the same way.

## Effort

Small-to-medium: mostly moving `require_relative` lines into `autoload` declarations and
finding the few places that reference a constant before its namespace is set up (the
emitters referencing `Schema`, `Message` reopened by `builder.rb` and `view.rb`, which must
move those definitions to where the autoload can find them). The measurement above is the
acceptance test: 82.5 ms to under 10 ms for `require "protostar"`.
