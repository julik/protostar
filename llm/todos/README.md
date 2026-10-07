# llm/todos

One file per idea or lead that is not scheduled as a workstream. Each says its status, where
it came from, and what doing it would take. Promote one to `llm/instructions/ws*.md` when it
gets picked up.

- `inline-rbs-annotations.md`: `--rbs_out=inline` as an opt-in `# @rbs!` block
- `yjit-polymorphic-call-sites.md`: codec speed under YJIT drops once many classes are loaded
- `error-message-rough-edges.md`: two error messages that do not say what went wrong
- `github-install-routes.md`: README install lines need the repo public; Bundler override notes
- `introspectable-message-classes.md`: Klass.reflection, registry, sizes, explain printers
- `marshal-and-json-round-trips.md`: Marshal as wire bytes, as_json for Rails, ActiveJob serializer
- `pure-ruby-codec-go-brrr.md`: the benchmark harness and every move to close the gap with the C extension in pure Ruby
- `thin-native-codec.md`: an optional, thin C gem for encode and decode only, same objects, same bytes
- `fiber-local-arenas.md`: an experiment with per-Fiber object pools and scratch buffers for decode and build
- `registries-not-global.md`: Protostar::Registry as an object you hold, Ractor-shareable when frozen, generated files that do not self-register
- `rbs-by-default.md`: `--ruby_out` writes the `.rbs` next to the `.rb` unless `--no-rbs`
- `generated-code-linter-guards.md`: rubocop and standard disable wrappers, frozen string literals stay on
- `lint-command.md`: `protostar lint`, Rust-style diagnostics with spans, codes and help, plus best-practice rules led by "required is forever"
- `builder-streaming-to-appendables.md`: Builder writes to any appendable or IO, and streams as far as the wire format allows, measured
- `diagnostics-twice-as-good.md`: did-you-mean suggestions, teaching notes, cross-file spans and fixes, lint reports everything, lint per input
