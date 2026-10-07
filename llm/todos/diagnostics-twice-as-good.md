# Diagnostics twice as good as protoc: did-you-mean, notes, cross-file spans, lint per input

**Status:** feature request from Julik, 2026-10-07, after a side-by-side of protoc 36.2 and
`protostar lint` (PR #5). Depends on PR #5 being merged. Not scheduled.

## Where we stand after PR #5

Every compiler error renders with its source line and span, a related span when two places
are involved, a `help:` with the fix, a code with `--explain`, colour, JSON and GitHub
output, and a lint layer protoc does not have. Three cases from the comparison:

```
protoc:    dup.proto:5:25: Field number 1 has already been used in "shop.Order" by field "id". Next available field number is 2.
protostar: both lines shown, "first used by `id`" and "reused here", help with the next number

protoc:    scope.proto:5:3: "Bar.Baz" is resolved to "Foo.Bar.Baz", which is not defined. The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., ".Bar.Baz") to start from the outermost scope.
protostar: the span, help: write `.Bar.Baz`; but protoc's one sentence of *why* was dropped

protoc:    typo.proto:4:3: "Timestmap" is not defined.
protostar: the span and "not found in this scope"; no better than protoc on substance
```

## The five steps

1. **"Did you mean".** The linker's symbol table holds every visible symbol, so an
   unresolved type, extendee, enum value, option name, or text-format field name gets a
   suggestion by edit distance (Damerau-Levenshtein, threshold scaled to length, at most
   three candidates, exact-case match first), rendered as rustc does:
   `help: a message with a similar name exists: `google.protobuf.Timestamp`` with a related
   span on the `import` line when it comes from an import, and a `fix:` when the suggestion
   is unique. Cover: type names (`L0203`), extendees, enum value defaults, option names and
   `(ext.names)`, text-format aggregate field names, rpc input and output types, and lint's
   own `--rules` and `--except` arguments. Suggest symbols that exist in the pool but are not
   imported with the import line to add, and symbols that exist in a different package with
   the qualified name.
2. **Notes that teach.** Every error whose cause is not obvious from the span gets a
   `note:` line stating the mechanism in one sentence, and `--explain CODE` carries the long
   form with an example. Start with: the first-component rule (restore protoc's sentence as
   the note and keep the terse help), proto3 restrictions (why no `required`, no defaults,
   first enum value zero), json_name conflicts (what the JSON mapping does), oneof rules,
   editions feature errors (what the feature controls), and reserved-range use (what
   reserving protects against). Write the catalogue entries so `--explain` reads like a
   short man page, not a restatement of the message.
3. **Cross-file spans and fixes.** When a symbol exists in a file that is not imported,
   show the file's definition as a related span and offer `fix: add `import "x.proto";``.
   For unused imports (`IMPORT_USED`) offer the removal as a fix. For a symbol visible
   through a non-public import two hops away, name the hop and the `import public` that
   would expose it. `--fix` applies import additions and removals; they are unambiguous.
4. **Everything at once in lint mode.** `compile` stops where protoc stops: the first bad
   option per element, no validation after link errors. Nobody pins `lint`'s output, so
   lint continues: interpret every option and report every bad one, run the validator even
   when the linker reported errors where the validator's inputs still exist, and say in the
   summary how many were found. Keep `compile` protoc-identical; the corpus tests stay.
5. **Lint each input in its own pool.** Lint built every input into one pool the way `buf`
   does, so Google's corpus produced 61 false symbol clashes between alternative files.
   Compile each named input in its own pool (imports shared through a read-only parent
   pool, the registries brief's parent idea applies here too), lint each result, and report
   genuine clashes between inputs as one lint warning (`DUPLICATE_SYMBOL_ACROSS_INPUTS`)
   with both definitions as spans, rather than as compiler errors. Rerun the corpus smoke
   test and put the new counts in the PR.

## Tests

- Suggestion quality: a golden per case above with the expected candidate order, and a
  negative test that nothing is suggested below the threshold (`Foo` for `Timestamp`).
- Every `note:` and `--explain` entry pinned; a test that each code with a note also has an
  `--explain` body longer than its message.
- Cross-file fixes applied on a temp copy, then recompiled clean.
- Lint-mode completeness: a file with three bad options reports three, `compile` still
  reports one.
- Per-input pools: the corpus smoke run has zero L02xx clash errors; two inputs defining the
  same symbol produce the new warning with two spans.

## Effort

Two to three days on the diagnostics layer and the lint runner; the suggestion engine and
the explain catalogue are most of it.
