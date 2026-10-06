# Inline RBS annotations in generated files

**Status:** idea, not scheduled. Raised 2026-10-06.

## The ask

Emit RBS inline in the generated `_pb.rb` instead of (or beside) the separate `.rbs`
that `--rbs_out` writes today.

## Why it is not simply "write the comments in"

- Inline RBS attaches to Ruby syntax (`# @rbs` above a `def`, `#:` above an
  `attr_reader`). A generated `_pb.rb` has none of that: it is a `Protostar::DSL.file`
  block plus constant assignments, and the accessors are made at load time with
  `class_eval`. The only inline form that fits is a `# @rbs!` block, which embeds raw
  RBS declarations in a comment. That is the same text as the `.rbs` file, relocated.
- Nothing reads inline annotations directly. `rbs` 4.2 has no inline command; the
  separate `rbs-inline` gem (0.14) extracts them into `.rbs` files, which Steep,
  `rbs validate` and TypeProf then consume. Sorbet reads `#:` comments only on real
  `def`s, so it gains nothing from an `@rbs!` block.
- Size. For `examples/03_compose_and_send_over_http/checkout.proto` the `.rb` is 30 lines
  and the `.rbs` is 69. Inlining more than triples the generated file, which is meant to
  be read.

| Option | Read directly by | Consumer build step | Generated file |
| --- | --- | --- | --- |
| Separate `.rbs` (today) | Steep, `rbs validate`, TypeProf, Sorbet via rbs-to-rbi | none | 30 lines |
| Inline `# @rbs!` block | nobody until `rbs-inline` extracts it | `rbs-inline` | about 100 lines |

## Proposed shape, if a consumer asks for it

- Keep separate `.rbs` as the default.
- Add `--rbs_out=inline` (and the matching `Emitters::Rbs` option): the same declarations
  the `.rbs` emitter produces, written as one `# @rbs!` block at the end of the `_pb.rb`,
  after the constants, so the readable part stays on top.
- Google-format output (`--google_out`) is unaffected; protoc's own generator writes
  separate `.rbs` and the byte-for-byte goldens stay.
- Tests: for every corpus file, running `rbs-inline` over the inline output must produce
  exactly the `.rbs` the separate emitter writes; `rbs validate` over that result. This
  makes `rbs-inline` a development dependency only.
- Docs: one paragraph in the README's RBS section and a line in `CHANGELOG.md`.

Effort: small, one emitter option plus tests. Value today: none without a concrete
consumer running `rbs-inline`; revisit when one appears or when `rbs` itself reads inline
annotations.
