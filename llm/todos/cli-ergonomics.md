# CLI ergonomics: `protostar file.proto` should just work

**Status:** feature lead from Julik, 2026-10-06. Small, not scheduled.

## Today

The CLI mirrors protoc's flags exactly, which is right for drop-in use and wrong for the
first five minutes:

```console
$ protostar examples/03_compose_and_send_over_http/checkout.proto
Unknown command: examples/03_compose_and_send_over_http/checkout.proto
$ protostar compile examples/03_compose_and_send_over_http/checkout.proto
Missing output directives.
$ protostar compile -I examples/03_compose_and_send_over_http checkout.proto
Missing output directives.
```

Three things a newcomer has to learn before anything happens: the `compile` subcommand,
that `-I` must name the directory the file lives in (protoc's rule: a file is addressed
relative to an include root), and that an `--*_out` is mandatory.

## Wanted

1. **`compile` is the default command.** `protostar FILES...` means `protostar compile
   FILES...`. The subcommand stays for scripts; `--version` and `--help` keep working.
2. **The default include root is the file's own directory.** When no `-I` is given, each
   input file's directory becomes an include root and the file is addressed by its
   basename, so `protostar path/to/checkout.proto` compiles `checkout.proto` with
   `path/to` on the search path. Explicit `-I` keeps protoc's behaviour unchanged. When
   two inputs live in different directories, both directories are roots, in the order
   given; imports between them resolve as they would under protoc with those roots. The
   bundled `google/protobuf/*.proto` stay on the path last, as now.
3. **One file and no output: write Ruby to stdout.** `protostar checkout.proto` prints the
   native `_pb.rb` to stdout, so `protostar checkout.proto > checkout_pb.rb` and
   `protostar checkout.proto | less` work. Diagnostics stay on stderr. Only the native
   Ruby goes to stdout; the other emitters need an explicit `--*_out`.
4. **Several files and no output: fail.** `protostar a.proto b.proto` with no `--ruby_out`
   exits 1 with one line saying which output flag to add, since two files cannot share
   stdout meaningfully. Same for one file with `--include_imports`-style multi-file output.
5. **Keep the name mapping.** With an output directory the generated file names follow the
   same rule as today (`foo/bar.proto` to `DIR/foo/bar_pb.rb` relative to the include root),
   which with the default root means `DIR/bar_pb.rb`.

## Edge cases to pin in tests

- A file given with a path and an explicit `-I` that does not contain it: protoc's error,
  unchanged.
- The same basename in two input directories: a clear error naming both paths.
- An import that resolves only through a directory the user did not pass: the usual "not
  found" diagnostic, plus a hint line suggesting `-I` when a file of that name exists next
  to one of the inputs' directories' parents (keep the hint to one level up, nothing clever).
- stdout mode with a file that has parse errors: nothing on stdout, errors on stderr, exit 1.
- `protostar -` is not supported; say so.

## Not changed

`protoc-gen-protostar` (the plugin) and every existing flag. The README's first example
becomes the one-liner, with the flag form kept for the "like protoc" paragraph.

## Effort

Small: option parsing and path defaulting in `lib/protostar/cli.rb`, a stdout emitter path,
tests in `test/cli/`, the README example, a CHANGELOG line.
