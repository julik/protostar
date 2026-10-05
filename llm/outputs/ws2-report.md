# WS2 report: the compiler front end (`Protostar::Compiler`)

## What was built

`lib/protostar/compiler.rb` and `lib/protostar/compiler/` (6,160 lines), required from `lib/protostar.rb`:

| File | Port of | Contents |
|---|---|---|
| `lexer.rb` | `io/tokenizer.cc` | tokens, 0-based positions (tab = next multiple of 8), every escape, ParseInteger/ParseFloat/ParseStringAppend, `next_with_comments` + CommentCollector |
| `parser.rb` | `compiler/parser.cc` | function-by-function port incl. error recovery, map entries, groups, synthetic oneofs, extension-range option source-info copying, reserved, visibility, editions |
| `ast.rb` | the parser's `FileDescriptorProto` | nodes with `positions` (protoc's SourceLocationTable kinds); `to_h` is exactly protoc's parser output |
| `source_info.rb` | LocationRecorder, UpdateSourceCodeInfo | locations in protoc's order; option paths rewritten after interpretation |
| `symbol_table.rb` | FindSymbol / LookupSymbolNoPlaceholder | local AST symbols + pool, import/public visibility, packages, unused-import tracking, protoc's failure explanations |
| `linker.rb` | DescriptorBuilder build + cross-link phases | AddSymbol, field/range/enum checks, field-number hints, type resolution, symbol visibility, CopyTo-shaped hash |
| `option_interpreter.rb` | OptionInterpreter | two passes (non-extension, extension), unknown-field-style accumulation then fold, "already set", ranges, sibling enum values, features checks between passes |
| `text_format.rb` | a slice of `text_format.cc` | aggregate option values, `[ext]`, Any (`[type.googleapis.com/..]`, encoded by a tiny private `WireEncoder`) |
| `validator.rb` | ValidateOptions phase and after; CLI checks | proto3 rules, JSON-name conflicts, maps, features, extension declarations, enums/aliases, lite, naming style, proto limits, STRICT visibility, feature lifetimes; CLI: generic-services warning, 19000-19999, option targets, max edition |
| `retention.rb` | `compiler/retention.cc` | source-retention stripping incl. source locations |
| `run.rb` | the importer / CLI driver | depth-first loading, recursion detection, diagnostics order |
| `compiler.rb` | facade | `Compiler`, `Error`, `Diagnostic`, SimpleDtoa/SimpleFtoa/CEscape |

Bundled includes under `lib/protostar/compiler/include/` (14 files + LICENSE); the gemspec now packages them.

`script/extract_parser_cases.rb` → `test/corpus/parser_cases/cases.json` (239 cases + 28 SourceInfoTest cases);
`script/record_validation_cases.rb` → re-records protoc's output into `test/compiler/validation_cases.rb`.

Facade: `Compiler.new(include_paths:, pool:, bundled_includes: true)`, `#compile(names, source_info:, retain_options:, sources:)`,
`#compile_to_hashes`, `#diagnostics` (warnings of the last compile), `#resolve(name)`, `Compiler::INCLUDE_DIR`.

## Results

- **Tier A: 107/107** corpus goldens equal exactly (every file of each set, protoc's file order, `Ractor.shareable?`),
  with `:__extensions` removed from our side only, since protoc's JSON cannot hold extensions. Diagnostics over the corpus
  equal protoc's (only the 6 generic-services warnings).
- **Custom options: 107/107** via the oracle: every options message of every file is decoded from the `.binpb` with a pool built
  from the golden itself and printed as JSON with `[extensions]`, and compared with ours. This covers what tier A strips.
- **Tier B: 107/107** source info equal location for location (paths, spans, comments) against the `.binpb` via the oracle.
- **parser_unittest.cc: 239/239** extracted cases (90 parse-to, 99 parse errors, 2 warnings, 48 validation) plus **28/28**
  SourceInfoTest cases (spans, comments, every location claimed), plus hand versions of the 5 computed-input cases.
- **Validation: 116 snippets**, each run through protoc 36.2 and recorded; 115 match line for line, 1 is a pinned deviation (below).

Test runs: 970 total (759 compiler); `bundle exec rake` clean (970 runs, 216 oracle skips, standard clean); with
`BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`: 970 runs, 131,471 assertions, 0 skips; green on Ruby 3.2.2 and 3.4.1.
Timing: whole corpus tier A 5s; `unittest.proto` 100ms with descriptor.proto pooled; parsing it 26ms.

## Deviations from the spec, and why

1. **Own symbol table instead of `Schema::Resolver`.** The linker must resolve against the AST before any descriptor
   exists and needs protoc's exact failures (pool-wide lookup with "seems to be defined in", the not-aggregate
   continuation, packages). `SymbolTable` mirrors protoc's rule; `test/compiler/resolver_test.rb` runs WS1's resolver
   cases as `.proto` and asserts `Schema::Resolver` agrees on each built file.
2. **Option types come from a structural build.** Option interpretation reads `Schema::Message`s: pool files, and for the
   file being linked a `Schema::Builder` build of itself without options (so descriptor.proto and same-file custom
   options work). Files that see no descriptor.proto use a private compile of the bundled one (protoc's compiled-in pool).
   Each file is built 2× (3× when returned stripped).
3. **Two pools' worth of files.** `compile` adds unstripped files to the pool (protoc's pool keeps source-retention
   options, and later files are validated against them, e.g. extension declarations) but returns what
   `--descriptor_set_out` writes: source-retention options and their locations stripped, linked against stripped
   imports kept in a private output pool. `retain_options: true` returns the pool's files.
4. **19000-19999 is not a DescriptorPool error** in protoc 36.2; it is a command-line check with no position. Implemented as such.
5. **Command-line behaviour is the default.** Unused-import warnings (named files only), naming style, proto limits,
   symbol visibility, feature-support validation, extension declarations, option targets, max edition and the
   generic-services warning are protoc CLI checks; `compile(..., protoc_cli: false)` (`@api private`) gives a bare
   DescriptorPool instead, as parser_unittest.cc's validation cases need ("has not been loaded", no CLI checks).
6. **Diagnostic file names are the virtual names**, not the disk paths protoc prints (`a.proto`, not `src/a.proto`).
7. **`java_features.proto`** is not in the corpus; it was downloaded from the v36.2 tag on GitHub.
8. Builder errors on our own hash would be internal bugs; they surface as position-less diagnostics, never seen.

## Known differences from protoc

- **Cross-file extension number clash**: protoc warns and accepts; `Schema::Pool#add` raises, so we report it as an error.
  Pinned in `validation_test.rb` (`DEVIATIONS`). **Schema change requested:** `Pool#add` should accept a second extension
  with an already used extendee/number from another file (protoc's `tables_->AddExtension` failure is a warning), or offer
  a non-raising mode.
- Multiple unused imports: protoc iterates a hash set, so its order is unspecified; we use import order.
- Missing `import option` files: protoc 36.2 aborts with a CHECK failure when writing the descriptor set; we print
  "File not found." and continue.
- Not implemented: `ValidateOptionImports`' debug_redact check, `CheckEnumCustomStringUniqueness`'s alias/custom
  JSON-string checks beyond plain names, text-format corners (`allow_f_after_float`, `#` comments, field numbers),
  placeholder/lazy-dependency pool modes, `--direct_dependencies`.
- Float custom-option values are stored as the float32 value (as decoding would give), not the literal.

## For WS4 (Ruby codegen and CLI)

- Use `compile` (stripped, what protoc embeds) for generated descriptors; `retain_options: true` only if you need
  source-retention options. `compile_to_hashes` gives the `FileDescriptorProto` hashes; `sources:` compiles in-memory text.
- Custom options are under `options.extensions` by full name; message-valued ones are nested hashes with their own
  `:__extensions`; `Any` values are `{type_url:, value: <bytes>}`.
- `Diagnostic#to_s` is protoc's format; `Error#message` joins them. Warnings of a successful compile are in `#diagnostics`.
- A CLI wanting protoc's exact stderr must map virtual names back to disk paths.
- The pool is shared across `compile` calls; recompiling a changed file needs a fresh pool.
- To refresh fixtures: `BUNDLE_WITH=oracle bundle exec ruby script/extract_parser_cases.rb`, `ruby script/record_validation_cases.rb`.

## Open questions

1. Should the `Pool` extension clash become a warning (see above)? It needs a Schema change.
2. Should `compile` return the pool's own objects (simpler identity) and strip only in `compile_to_hashes`/codegen?
   Today returned files are stripped copies, not pool members.
3. Diagnostics: keep virtual names, or carry the resolved disk path as well for CLI parity?
