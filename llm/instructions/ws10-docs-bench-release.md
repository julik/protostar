# WS10: documentation, benchmarks and the 0.1.0 release

Make protostar usable by someone who has never read this repo. Read every report in
`llm/outputs/` first; they hold the facts the docs must state and the numbers the
benchmarks must reproduce.

## Deliverables

- `README.md` for the `protostar` gem, in the style of Julik's other gems (short
  sentences, imperative, code fences that each do one thing): what it is, install,
  compile a `.proto` (CLI, Rake, plugin), use the generated classes (new, accessors,
  encode, decode, JSON, text, views, Ractors), the DSL by hand, the well-known types,
  the gRPC stubs, a section "Replacing google-protobuf" that links to the shim's README,
  what is not supported (extensions as first-class fields, the legacy DSL), performance
  expectations with a link to the benchmark table, and how the test corpus and protoc
  goldens work for contributors.
- `shims/google-protobuf/README.md`: the three install routes with their exact Gemfile
  lines (git source with `glob:`, the `bundler-override` plugin fallback and its
  caveat about Bundler 4.1's `override` keyword, require-order without Bundler), the
  known-differences list, how to verify `Google::Protobuf::IMPLEMENTATION`.
- `docs/migration.md`: moving an app or a gem from google-protobuf plus protoc to
  protostar, both the native path and the shim path, with the gotchas the reports list
  (two pools, constant names, closed enums, `RangeError`).
- `docs/design.md`: the architecture in prose, one page, from the plan document:
  descriptor model, compiler, codec, views, JSON and text, DSL and emitters, the shim
  and its two pools, Ractor rules, the testing tiers.
- `bench/`: one `rake bench` that runs every existing benchmark (`codec_bench.rb`,
  `view_bench.rb`, the builder measurement from WS9, class definition time, compiler
  time over the corpus) and prints one table; the table committed in
  `docs/benchmarks.md` with the Ruby version, YJIT on and off, and the google-protobuf
  C extension column measured in a throwaway GEM_HOME. Numbers are reported, never
  gated.
- `CHANGELOG.md` for 0.1.0 with one line per capability, and the gemspec metadata
  checked (`gem build` for both gems succeeds, the file lists are complete, the shim
  gem depends on `protostar` with the same version).
- YARD: `rake yard` builds with no warnings for the public API; `.yardopts` committed.
- CI: the full matrix green, including the `shim` and `conformance` jobs.

## Testing

A `test/release/` suite that builds both gems into a temp dir, installs them into a
throwaway GEM_HOME, and in a subprocess with no bundle: requires `protostar`, compiles
a `.proto` with the CLI, loads the output, round-trips a message; then requires
`google/protobuf` from the shim and loads a Google-format file. This is the only test
that touches installed gems.

## Out of scope

Publishing to rubygems.org (Julik does that), the pbbuilder fork's own release.
