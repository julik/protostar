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
- `cli-ergonomics.md`: compile by default, include root from the file's directory, stdout for a single file
- `registries-not-global.md`: Protostar::Registry as an object you hold, Ractor-shareable when frozen, generated files that do not self-register
