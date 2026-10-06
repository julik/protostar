# Emit `.rbs` by default

**Status:** feature lead from Julik, 2026-10-06. Small, not scheduled. Pairs with
`cli-ergonomics.md`.

## Today

`--rbs_out=DIR` is opt-in. Next to `--ruby_out` it writes signatures for protostar's own
classes (WS13); alone or with `--google_out` it writes protoc's RBS, byte for byte.

## Wanted

- `--ruby_out=DIR` writes `foo_pb.rbs` next to `foo_pb.rb` unless `--no-rbs` is given.
  `--rbs_out=DIR` keeps working for people who want the signatures elsewhere (a `sig/`
  tree is the RBS convention), and when it is given the default placement is off.
- In the stdout mode of `cli-ergonomics.md` (one file, no output directory) only the Ruby
  is printed; `--no-rbs` is implied, since two files cannot go to one stream.
- `--google_out` stays as protoc behaves: no RBS unless `--rbs_out` is given, because
  protoc's own generator does not write any by default and the goldens pin that output.
- The plugin (`protoc-gen-protostar`) follows the same default: `ruby` output includes RBS
  unless the parameter says `no-rbs`.
- The Rake task helper and the README examples show the `.rbs` appearing, and the
  `examples/` playbooks regenerate with the signatures committed (`rake examples:check`
  covers them).

## Why default on

The signatures are correct by construction (`rake rbs:validate` checks all 98 corpus
files), cost nothing at runtime, and a user who does not run Steep or Sorbet loses nothing
by having the file next to the Ruby. A user who does run them gets types without reading
the help.

## Effort

Small: a default in `lib/protostar/cli.rb` and the plugin, a flag, tests in `test/cli/`,
regenerated examples, a README line, a CHANGELOG line.
