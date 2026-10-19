# Conventions for every protostar workstream

Read `genesis.md` for the goal. Read this file before touching code. Your own
workstream spec is `ws<N>-*.md` next to this file; it wins over this file where
they disagree.

## Ground rules

- Pure Ruby. No native extensions, no runtime gem dependencies, ever. Ruby 3.2 is the
  floor: no syntax or stdlib that 3.2 lacks. CI runs 3.2, 3.3, 3.4 and 4.0.
- Minitest under `test/`, files named `*_test.rb`, run with `bundle exec rake test`.
  `bundle exec rake` runs tests and `standard`; both must be clean before you report done.
- `# frozen_string_literal: true` at the top of every Ruby file.
- Ractor safety is a design constraint, not a test afterthought: anything reachable from
  a descriptor or a generated class after load is frozen and `Ractor.shareable?`. No
  class-level mutable caches populated lazily at runtime. If a cache is needed, build it
  at definition time and freeze it.
- Public API gets an RDoc comment (markdown prose, no YARD tags) and its type as inline RBS
  (`#:` above the `def`, `#: Type` after an `attr_*`); internal API a trailing `# :nodoc:`.
  `sig/` and `rbi/protostar.rbi` are generated from those (`rake types:generate`); see
  CONTRIBUTING.md, "Types and docs". Implementation comments are rare and explain *why*, never
  narrate the next line. No section banners, no "Step 1" scaffolds, no TODO farms.
  Trailing fragments for magic values are fine: `# wire type for length-delimited`.
- Prefer plain Ruby objects with `attr_reader` over `Struct` or `Data` where object
  graphs have cycles. Freeze everything at the end of construction.
- Performance matters but correctness against protoc comes first. Use `String#getbyte`,
  `byteslice`, `unpack1`, and avoid per-byte object allocation in hot loops.

## The corpus and its goldens

`test/corpus/protobuf/` is a vendored slice of the protobuf repo at `v36.2` (see `PIN`),
BSD licensed, with its LICENSE alongside. `test/corpus/goldens/` holds, for every corpus
`.proto`, a `FileDescriptorSet` as protoc 36.2 produced it with `--include_imports
--include_source_info` (`.binpb`) and the same set rendered as protoc JSON without source
info (`.json`). `test/support/corpus.rb` has the paths and the include roots protoc used.
Never edit the corpus or goldens by hand; `rake corpus:fetch` and `rake corpus:goldens`
regenerate them. protoc itself is at `~/.cache/protostar/protoc-36.2/bin/protoc` on this
machine (or `rake protoc:install`). Tests must pass without protoc present.

The C-extension `google-protobuf` gem is available as an oracle when the bundle is
installed with `BUNDLE_WITH=oracle` and tests see `PROTOSTAR_ORACLE=1`. Such tests must
`skip` cleanly when the gem is absent.

## Working in your worktree

- You are in a git worktree on your own branch. Commit as you go with clear messages.
  Do not push, do not merge, do not touch branches other than yours.
- Stay inside the files your spec names. If you need something from another workstream
  that does not exist yet, write the smallest stub you need under your own namespace and
  say so in your report; do not implement another workstream's scope.
- When your spec is ambiguous, pick the behaviour protoc has and write a test that pins it.
  When protoc's behaviour is unknowable from the corpus, say so in the report.
- Finish with `llm/outputs/ws<N>-report.md`: what was built, what the tests cover, what
  was left out and why, open questions, and anything the next workstream must know.
  Be precise and brief. Numbers over adjectives.
