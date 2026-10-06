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
