# WS10 report: documentation, benchmarks and the 0.1.0 release

Three code pre-steps, then the spec's deliverables. Nine commits on the branch, every suite
green after each code commit. Nothing pushed or merged.

## Commits

| Commit | What |
|---|---|
| `8b75245` | (a) DSL spelling: `visibility: :local`/`:export`, `extensions:`, `unknown_fields:`; old spellings read with a deprecation warning; generated files regenerated |
| `3df8f35` | (b) `Compiler#compile_to_hashes` deprecated |
| `09c6088` | `rake bench`, `bench/` rewritten on one harness, `docs/benchmarks.md` |
| `7df06b3` | `test/release/` |
| `77d2bdd` | README, shim README, `docs/migration.md`, `docs/design.md`, CHANGELOG |
| `6913bd3` | `.yardopts`, `rake yard` with no warnings |
| `64f2b62` | CI: `rake yard` in the lint job |
| `96c7adc` | benchmarks: schema loading as best-of-10, table rerun |

## Pre-steps

**(a) DSL spelling.** The native emitter writes `visibility: :export` (was
`:VISIBILITY_EXPORT`), `extensions:` at every depth of an option value (was `__extensions:`
inside nested values), and `unknown_fields:` as a binary String (was `__unknown_fields:` as
`[number, wire_type, bytes]` triples). `unknown_fields:` is now an ordinary keyword, so such
options no longer force the verbatim `options:` form. The ambiguity WS14 kept `__` for (a
custom option message with a field named `extensions`) is solved with a String key:
`"extensions" => ...` names the field, `extensions:` the extensions; the emitter writes that
form. The old spellings are still read until 0.2.0. Every occurrence warns, in
Ruby's `:deprecated` category (shown under `-w` or `-W:deprecated`), naming the first caller
outside `lib/` (`Protostar.deprecated`, `@api private`). Tests: `dsl_test.rb` +2 (new
spelling including the String key and emitter output; old spellings build the same options
and produce exactly three warnings pointing at the caller), `ruby_emitter_test.rb`
expectations updated. Regenerated: `bootstrap:regenerate`, `conformance:regenerate`,
`examples:regenerate`, the shim's `rake generate`. Only
`conformance/generated/.../test_messages_edition_unstable_pb.rb` changed (4 lines); the
other committed generated files contain neither spelling. `docs/schema-api.md` updated.

**(b)** `Compiler#compile_to_hashes` has `@deprecated` in YARD and warns the same way,
pointing at `compile(names).map { |f| f.to_proto.to_h }`. `facade_test.rb` asserts the
result, its equality with that expression, and the warning. compiler-internals.md updated.

**(c) Decided, no code:**
1. Option readers return nil when unset; descriptor.proto's defaults are not applied (WS14's
   reasoning stands: `packed` unset and `packed: false` differ for feature inference and for
   `to_proto`).
2. Whether `json_name` was explicit stays unrecorded; the Google-format emitter and the shim
   keep treating a json_name equal to the derived one as unset (WS4 deviation 4). No corpus
   file is affected.
3. Views get no reflection object.

## Deliverables

| Deliverable | Where | Checked how |
|---|---|---|
| README | `README.md` | every snippet run from `tmp/readme/` (CLI, plugin under protoc 36.2, runtime compile, codec, JSON, text, views, Ractors, reflection, Builder, DSL, WKT, gRPC server and client on native classes); outputs pasted |
| Shim README | `shims/google-protobuf/README.md` | the three routes resolved for real, see below; known-differences list added |
| Migration | `docs/migration.md` | native and shim behaviour run side by side on one proto2 file (errors, closed vs open enums, containers, two pools, cross-pool assignment) |
| Design | `docs/design.md` | one page: model, compiler, codec, views, JSON/text, DSL, Builder, shim and its two pools, Ractor rules, test tiers |
| Benchmarks | `bench/`, `rake bench`, `docs/benchmarks.md` | below |
| CHANGELOG | `CHANGELOG.md` | 0.1.0, one line per capability, deprecations, not-supported |
| Gems | both gemspecs | `gem build` succeeds for both, no warnings; file lists equal the tracked files exactly (140 and 30 files); shim depends on `protostar (= 0.1.0)` |
| YARD | `.yardopts`, `rake yard` | `yard doc --fail-on-warning` passes; 80.4% documented (the undocumented are internal constants and a few internal methods) |
| Release test | `test/release/release_test.rb` | 4 runs, 13 assertions, ~2 s, no network; green on 3.2.2, 3.4.1, 4.0.0 |

### Shim install routes, as resolved

- **git + `glob:`** (both forms) and **`path:`**: the shim's own `bundler_test.rb` resolves
  them against a local clone. The real `https://github.com/julik/protostar.git` answers 403
  to an anonymous clone today, so the README's `github:` lines resolve only once the
  repository is public.
- **Gems pinning google-protobuf 3** (`googleapis-common-protos-types` 1.8-1.14 want
  `~> 3.18`, grpc 1.50 `~> 3.21`): without help `bundle lock` fails (message pasted in the
  README). Bundler **4.1.0.beta1**'s `override "google-protobuf", version: ">= 3.18"`
  resolves and loads (`:PROTOSTAR`), but `BUNDLE_FROZEN=true bundle install` then refuses
  the Gemfile even right after a plain install wrote a satisfying lockfile
  ([rubygems#9907](https://github.com/ruby/rubygems/issues/9907), open). On Bundler 4.0.18
  the **bundler-override** plugin 0.4.0 resolves the same case; it prepends its own
  `Bundler::Dsl#override`, so it must go before Bundler 4.1's is used. Old gems may ship
  pre-3.21 `_pb.rb` files: googleapis-common-protos-types 1.4.0 resolved with the plugin and
  then raised the shim's `NotImplementedError` for `DescriptorPool#build`; 1.14.0 loads.
  No Bundler 4.1 final exists yet (newest release 4.0.22).
- **Without Bundler**: with Google's 4.36.2 C gem and the shim both in one GEM_HOME, a plain
  `require "google/protobuf"` activates the shim (4.36.2.1 is higher), `gem
  "google-protobuf", "= 4.36.2.1"` first is the way to be sure, and asking for the shim after
  Google's gem is active raises `Gem::LoadError`. 4.36.2 is Google's newest release today, so
  "a later Google release wins" is reasoned, not observed.

## Benchmarks

`rake bench` runs `bench/run.rb`: per side and YJIT setting a process with no Bundler; the
C extension comes from `tmp/bench/<ruby>/gem_home`, installed there on first use. Each
`bench/*_bench.rb` also runs alone (`BENCH_SIDE=google` for the C gem). The harness
(`bench/bench.rb`) replaces benchmark-ips, which is dropped from the gemspec. Ruby 3.4.11
(the only Ruby here built with YJIT), Apple M1 Pro:

| | protostar | YJIT | google-protobuf C | C, YJIT |
|---|---:|---:|---:|---:|
| decode TestAllTypes, 413 B | 42.9 µs | 30.5 µs | 3.07 µs | 2.71 µs |
| encode TestAllTypes | 30.0 µs | 11.9 µs | 0.92 µs | 0.88 µs |
| decode small, 50 B | 5.26 µs | 2.54 µs | 1.09 µs | 0.90 µs |
| encode small | 5.76 µs | 3.57 µs | 0.27 µs | 0.22 µs |
| 1 MiB: view, read two fields | 447 µs | 52.9 µs | | |
| 1 MiB: decode, read two fields | 1.4 ms | 593 µs | 265 µs | 262 µs |
| 1,000 friends: Builder.build | 10.1 ms | 2.7 ms | | |
| 1,000 friends: new + encode | 17.6 ms | 7.3 ms | 1.8 ms | 1.6 ms |
| define 160 classes (unittest + imports) | 176 ms | 181 ms | 0.54 ms | 0.55 ms |
| compile unittest.proto, fresh | 137 ms | 95 ms | | |
| whole corpus, 107 files | 4.23 s | 2.31 s | | |

The full table (frozen decode, view `to_h`/`to_message`, small views, the DSL load,
`add_serialized_file`, every compiler stage, allocations) is in `docs/benchmarks.md`.
Interpreter rows reproduce WS3/WS8/WS13/WS14 within a few percent on the same machine
(WS13's 39.2 µs decode on 3.4.1, here 42.9 on 3.4.11's interpreter; WS14's 3.95 s corpus,
here 4.23 s).

**The YJIT rows do not reproduce WS3/WS13** (12.9 µs decode, 1.31 µs small encode there;
30.5 and 3.57 here). Investigated: the old benchmark-ips script at HEAD gives the same 30.9
µs, and WS13's tree gives 13.3 µs, so it looked like a WS14 regression; the codec files did
not change in WS14. In a minimal script small encode is 1.1 µs on both trees, and 3.3-3.4 µs
on both once the process has run other message classes (WS13's tree after 1,000 TestAllTypes
round trips: 3.41 µs). WS14's fixtures load through `File.from_proto`, which decodes
descriptor messages with the bootstrap classes before anything is measured, so the bench now
always measures the polymorphic state. That is the realistic number for an app, and it is
documented as such. The cause (shared call sites in generated codec code going polymorphic
under YJIT) was not pinned down further; it is the most promising YJIT performance lead.

Not run: `script/pbbuilder_bench.rb` (Rails and the pbbuilder clones); `docs/benchmarks.md`
cites WS9's numbers for it, and the no-Rails builder rows cover the Builder itself.

## Tests

| Suite | Result |
|---|---|
| `bundle exec rake` (tests + standard), 3.4.1, 3.2.2, ruby-4.0.0 | 2,351 runs, 99,911 assertions, 0 failures, 335 skips each (WS14: 2,345) |
| oracle (`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`) | 2,351 runs, 246,068 assertions, 0 failures, 0 skips |
| `rake test:warnings` | no warnings from lib/ |
| `rake shim:test` | 997 tests, 149,446 assertions, 0 failures, 45 omissions |
| `rake conformance:run` | 5,648 passed + 1 expected failure; text format 909 passed |
| `bootstrap:check`, `examples:check`, `conformance:check`, `rbs:validate`, `rake yard` | pass |

New: `test/release/release_test.rb` (4), `dsl_test.rb` (+2), `facade_test.rb` (1 rewritten).
CI was not run (Actions is unreliable today); the lint job gained `rake yard`, and the
release test runs inside the existing `rake test:warnings` step.

## Found while documenting

1. **YJIT codec speed depends on process history** (above): 2.5-3x between a fresh process
   and one that has run other message classes.
2. **`Types::Registry#define(files.last)` raises when the imports were not defined first**
   ("comes from google/protobuf/timestamp.proto, which must be defined before ..."), and
   `define` takes one file. Runtime compilation needs `files.each { |f| registry.define(f) }`;
   the README shows that. Accepting the Array `compile` returns would be friendlier.
3. **Cross-pool assignment errors read oddly**: assigning the shim's
   `Google::Protobuf::Timestamp` to a native Timestamp field raises "expects a
   google.protobuf.Timestamp or a Hash, got <Google::Protobuf::Timestamp: ...>". Naming the
   expected class (`Protostar::Google::Protobuf::Timestamp`) would make the two-pool cause
   obvious.
4. **Shim `RepeatedField#<<` with a wrong type** says "Expected number type for integral
   field '' (given String)", with an empty field name. Whether the C gem also leaves it
   empty was not checked.
5. **`Timestamp#to_time` returns local time** (`1815-12-10 01:00:00 +0100` on this machine),
   as the gem does. Not a bug; the README avoids printing it.
6. **gRPC on native classes never loads google-protobuf**: a server and client with
   `--grpc_out` stubs over native messages ran with `defined?(Google::Protobuf) == nil`,
   although grpc's gemspec makes Bundler install some `google-protobuf`. Documented.
7. **The bench's old "define classes" figure** (a median of back-to-back redefinitions,
   204 ms) included collecting the previous round's classes; best-of-10 is 176 ms.
   WS13's tree and HEAD both define unittest.proto and its imports in 145-148 ms best-of-5
   outside the bench; there is no definition-time regression since WS13.
8. The shim gemspec has no `changelog_uri` (protostar's has); its licence is MIT while it
   ships BSD-derived generated files with a notice. Left for Julik to decide.

## For whoever releases

- Build: `gem build protostar.gemspec` and, in `shims/google-protobuf`, `gem build
  google-protobuf.gemspec`. Release both together; the shim pins `protostar = 0.1.0`.
- The README's `github:` install lines need the repository public.
- `WRITE=1 rake bench` regenerates the table; run it on a quiet machine with a YJIT Ruby
  (`RBENV_VERSION=3.4.11 ruby bench/run.rb --write` here).

## Open questions

1. Should `Registry#define` accept an Array of files (finding 2)?
2. Is it worth a day to find what goes polymorphic in the generated codec under YJIT?
3. Should the deprecation warnings be unconditional (plain `warn`) rather than in the
   `:deprecated` category, which Ruby hides by default? Chosen: the category, as Ruby's own
   deprecations are; `protostar compile` already writes the new spelling.
