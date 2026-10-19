# WS17: inline RBS as the one source of types, RDoc 8 for docs

Branch: on top of `ws16-rbi-out` (PR #7). Not pushed.

## What changed

| Before | After |
| --- | --- |
| YARD tags in `lib/`: ~490 `@param`, ~800 `@return`, 64 `@raise`, 217 `@api private`, never checked | 572 `#:` method signatures and 249 typed `attr_*` lines in `lib/`; prose docs; 156 trailing `# :nodoc:` |
| `sig/protostar.rbs` (415 lines) and `sig/protostar/lint.rbs` (216), hand-written | 144 generated `.rbs` files under `sig/` (one per `lib/` file, ~8.7k lines) + `sig/protostar_manual.rbs` (53 lines, hand-written) |
| `rbi/protostar.rbi` (849 lines), hand-written, a subset of the API, synced to the RBS by a test | `rbi/protostar.rbi` (7.4k lines), generated, all of `lib/`'s public methods |
| `rake yard`, `.yardopts` | `rake rdoc`, `.rdoc_options` |
| no type checking of `lib/` | `rake steep`: lenient profile, 0 diagnostics |

The shim (`shims/google-protobuf/lib`) got the same conversion: 116 `#:` lines, RDoc prose.
It ships no signature files, as before.

## Tools and versions

- **rbs-inline 0.14.0** (dev dependency, Ruby 3.1+) writes `sig/`. It is the only tool that
  writes `.rbs` files from inline annotations; rbs 4's own inline support reads them for
  type checking but does not write files. The annotations stay in the subset both read: `#:`
  method types, trailing `#:` on attributes and constants, `#[...]` on `include`.
- **rbs >= 4.0** (gemspec). rbs 4.2 needs Ruby 3.3; on 3.2 Bundler picks 4.1.3. Generated
  output is identical with 4.1.3 on Ruby 3.2.2 and 4.2.0 on 3.4.1 (checked).
- **RBI: our own translator in `script/types.rb`**, ~250 lines, from the resolved RBS
  environment (`RBS::Environment#resolve_type_names`) to Sorbet syntax. Chosen over spoom's
  `srb sigs translate`/`export` because it needs no extra gems (spoom pulls in
  sorbet-runtime and needs Ruby 3.3, export also needs tapioca), it reads the shipped RBS
  rather than the Ruby source, so the RBI cannot disagree with `sig/`, and the manual RBS
  goes through the same path. Ruby supplies only parameter names. Sorbet typechecks the
  result in the WS16 tests (`test_sorbet_accepts_the_corpus`, `test_sorbet_sees_through_the_classes`).
- **Steep 2.1.0**, dev only, from Ruby 3.3 (a conditional in the Gemfile).
- **RDoc 8.1.0** (dev dependency, Ruby 3.2+). It renders each `#:` signature under the
  method name, links the type names in it, and also reads `sig/`. `ri` shows the signature
  as a second call-seq (checked: `Protostar::Message.decode`, `Protostar::Builder.write`).

## The generator (`script/types.rb`, `rake types:generate` / `types:check`)

Besides running rbs-inline, it fixes three things rbs-inline 0.14 gets wrong:

- `alias_method` is ignored (only the `alias` keyword is read, and standard wants
  `alias_method`): added from the Prism tree.
- `attr_reader` under `class << self` comes out as an instance attribute: made singleton.
- a bare `module_function` stays on for every class and module after the one it is in
  (`Compiler::Emitters::Printer`'s methods came out as `self?.print` etc.): reset to
  instance methods unless the method really follows a `module_function` in its own body.

It strips the copied `#:`/`@rbs`/`:stopdoc:` lines from the doc comments it writes.
`types:check` regenerates in memory and fails on any difference or stale file; a test
(`test/rbi/signatures_test.rb`) runs it, as `bootstrap_test.rb` does for the bootstrap files.
The old test that compared the hand-written RBS and RBI method lists is gone.

RBI translation choices: overloads are merged into one sig (each parameter takes the union of
what the overloads give it, nilable when some overload lacks it), since Sorbet accepts several
sigs only in its own stdlib RBI; `instance` is `T.attached_class` in returns of class methods
and the class itself elsewhere; `self` in a parameter is the class; interfaces are
`T.untyped`; type aliases are expanded; private methods are left out; `IO::Buffer` gets a
stub class, `JSON::State` is untyped (Sorbet's RBI lacks both).

## What inline RBS could not say (`sig/protostar_manual.rbs`)

- the 17 class aliases (`Protostar::Timestamp = Google::Protobuf::Timestamp` etc.); rbs-inline
  0.14 types `X = Y #: class-alias` as `X: untyped`. `lib/protostar/short_names/*.rb` say
  `# rbs_inline: disabled`.
- type aliases and interfaces: `Message::Reflection::field_key`, `Builder::options`,
  `Builder::sink`, `Builder::_CacheStore`, `_Write`, `_Append`.

Also: a destructured parameter (`Parser#map_entry_field(name, number, (type, type_name))`) is
dropped by rbs-inline, so that method has an explicit `#:`. Methods defined from generated
source with `class_eval` (the per-field accessors, the codec) have no signature; generated
message classes get theirs from the `_pb.rbs`/`_pb.rbi` emitters, which are unchanged.
`#:` overloads must each fit on one line (a few long ones in `compiler.rb`, `builder.rb`).

## Steep

`Steepfile`: target `lib`, signatures `sig/`, `lib/protostar/google/` ignored (bootstrap
output), libraries json, stringio, pp, optparse, fileutils, open3, pathname, tmpdir,
`D::Ruby.lenient`. **0 diagnostics.** The default profile reports **596**: 228 are empty
`[]`/`{}` literals it wants annotated, most of the rest nil checks it cannot follow through
instance variables and `MatchData`, and calls on untyped DSL-made classes. No bug among those
read. One harmless Steep log line remains: its own note that the `#: instance` downcast in
`Message.decode` is checked both ways.

What the lenient run found, all fixed:

- `Text::Extensions#read` returns nil when the bytes do not read as the extension; typed
  `Array[untyped]?` now. `Parser#parse_visibility` likewise returns `[bool, Symbol?]`.
- ten methods that `yield` without a block parameter were typed as taking no block (so their
  RBS and RBI rejected a block); they have signatures now.
- `Builder::Generator.generate` is typed to return a `singleton(Builder)`.
- type assertions (`#: instance`) where Steep cannot see that `Codec::Decoder.decode(self, ...)`
  returns the receiver's instances; `Message.build`'s early return was split to carry one.

## Docs

`rake rdoc`: README is the main page, plus CHANGELOG and `docs/*.md`; `lib/protostar/google/`
and the bundled `.proto` includes are excluded. RDoc has no fail-on-warning flag, so the task
fails on any output besides progress and totals (checked with a broken `rdoc-ref`). Result:
no warnings, 57.98% documented by RDoc's count (it counts `:nodoc:`-free constants and
attributes without comments).

YARD tags became: parameters as a `- \`name\`: ...` list, `Returns ...`/`Raises X ...`
sentences, fenced code blocks (the 2-space-indented examples rendered as paragraphs in RDoc),
`{Ref}` as a plain name RDoc links. RDoc 8.1 reads a `# :nodoc:` on a line of its own as
applying to the rest of the enclosing class (it hid every method after the first one), so
`:nodoc:` goes at the end of the `def`/`attr_*`/`class` line, `# :nodoc: all` for internal
classes, and typed internal attributes sit between `:stopdoc:`/`:startdoc:`. CONTRIBUTING.md
says so.

## Gate

`bundle exec rake` (2510 runs, 0 failures; the two Sorbet tests ran with `SORBET=`), `rake
test:warnings`, `rake rbs:validate`, `rake types:check`, `rake steep`, `rake rdoc`, `rake
shim:test` (1006 tests, 0 failures), `bootstrap:check`, `conformance:check`, `examples:check`:
all green. CI's lint job now runs `types:check`, `steep` and `rdoc`.

## Notes for whoever rebases WS15 over this

Changes under `lib/protostar/codec/` are comments only (signatures and prose). After the
rebase run `rake types:generate`; new or renamed methods in the codec need a `#:` line if
they are meant to be typed, and `rake steep` will say where a signature no longer fits.

## Not done

- The shim's inline types are not checked in CI. Checked once against protostar's `sig/`:
  the only unresolved names are the shim's generated descriptor option and proto classes
  (`Google::Protobuf::FieldOptions` etc.), which have no RBS.
- `script/` keeps its YARD-style comments; it is not documented API.
