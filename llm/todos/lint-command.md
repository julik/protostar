# `protostar lint`: Rust-grade diagnostics and best-practice lints for `.proto` files

**Status:** feature request from Julik, 2026-10-07. Scheduled; a subagent picks it up
from this brief.

## The ask

Two things in one command, both built on the compiler we already have:

1. **Syntax and semantic verification that is very helpful.** The compiler already finds
   everything protoc finds, with protoc's wording. protoc's wording is one terse line.
   `protostar lint` should explain errors the way `rustc` does: the source line with a
   caret under the span, the related line when the error is about two places ("first used
   here" / "reused here"), a `help:` with the concrete fix, and an error code that can be
   looked up.
2. **Best-practice lints for protobuf**, the kind of thing `buf lint` and `protolint`
   check, led by the classic "`required` is forever" problem. Warnings, grouped into
   rule sets, each with the reason it exists and the fix.

## Shape of the command

```console
$ protostar lint acme/person.proto             # one or more files, or directories (recursive, *.proto)
$ protostar lint proto/ --format json          # editor- and CI-friendly; also `github` for workflow annotations
$ protostar lint proto/ --rules default,naming --except FIELD_NOT_REQUIRED
$ protostar lint proto/ --explain FIELD_NOT_REQUIRED
```

Exit codes: 0 clean, 1 lint warnings (unless `--warnings-ok`), 2 syntax or semantic errors.
Include roots follow `compile`'s rules (`-I`, else each input's own directory). Reads a
`.protostar.yml` next to the inputs or in the current directory for rule configuration:

```yaml
lint:
  rules: [default]            # named sets, or individual rule ids
  except: [PACKAGE_VERSION_SUFFIX]
  ignore: ["vendor/**"]
  allow_comment_directives: true   # `// protostar-lint: disable-next-line RULE` and `// protostar-lint: disable RULE` ... `enable`
```

## Diagnostics, the Rust standard

Every diagnostic, error or lint, renders as:

```
error[P0102]: field number 1 is already used in `p.A`
  --> link.proto:5:15
   |
 4 |   Missing m = 1;
   |               - first used by `m`
 5 |   int32 dup = 1;
   |               ^ reused here
   |
   = help: the next available field number is 2
```

- The primary span under a caret, secondary spans with dashes and their own labels,
  multi-line spans handled. Spans come from the AST's source locations, which the parser
  already records for source info; the linker's `Problem` carries the node and the
  position kind, so most errors already know their span. Where protoc reports only a
  line and column, underline the token at that position.
- A stable code per message (`P` for parse, `L` for link, `V` for validation, `W` for
  lint; numbered), and `--explain CODE` printing a paragraph with an example and the fix.
  The codes table lives in one file and a test checks every diagnostic the compiler can
  raise has one (walk the message strings in the compiler for the catalogue, so a new
  message without a code fails the test).
- `help:` and `note:` lines with concrete fixes. Some fixes can be mechanical: a `fix:`
  line showing the replacement, and `--fix` applying the safe ones (naming, missing
  `syntax`, enum zero value rename) with a diff printed and nothing written without the
  flag. Start with the few that are unambiguous.
- Colour when stdout is a TTY (respect `NO_COLOR`), plain otherwise; `--format json`
  emits one object per diagnostic (code, severity, message, file, spans, help, fix);
  `--format github` emits `::error file=...,line=...,col=...::` annotations.
- The compiler's `Diagnostic` grows the fields the renderer needs (spans, labels, help,
  code) without changing what `compile` prints by default, since `compile`'s protoc-shaped
  output is pinned by tests and by users' scripts. `compile --error_format=rich` opts into
  the renderer there too.
- Errors are rendered in the order the compiler reports them, which is protoc's order;
  the lint pass runs only on files that compiled, and reports per file.

## The lint rules, first cut

Each rule has an id, a one-line reason, a severity, a set membership, and a fix hint.
Sets: `minimal` (the ones no sane schema violates), `default` (minimal plus naming and
structure), `strict` (everything). Mirror `buf lint`'s rule names where the check is the
same, so people arriving from buf recognise them.

**Longevity, the "required is forever" family** (`minimal`):
- `FIELD_NOT_REQUIRED`: a proto2 `required` field, or editions `LEGACY_REQUIRED`, can
  never be removed or made optional without breaking every reader; explain why and say
  to use `optional` with validation in code.
- `NO_GROUPS`: groups are a proto2 relic that no other language tooling likes.
- `ENUM_ZERO_VALUE_SUFFIX` (`_UNSPECIFIED`) and `ENUM_FIRST_VALUE_ZERO`: the zero value
  is what every reader sees for an unset or unknown enum, so it must mean "unspecified".
- `FIELD_NUMBER_REUSE_RISK`: a message with gaps in its numbering and no `reserved`
  statement for the gap; the fix is `reserved` for deleted numbers and names.
- `RESERVED_NAMES_WITH_NUMBERS`: reserving a number without its name (or the reverse).
- `PACKAGE_DEFINED`: a file without a package lands every type in the global namespace.
- `IMPORT_NO_PUBLIC`, `IMPORT_NO_WEAK`, `IMPORT_USED`.
- `SYNTAX_SPECIFIED`: no `syntax` or `edition` line means proto2 by accident.

**Naming** (`default`): `FILE_LOWER_SNAKE_CASE`, `PACKAGE_LOWER_SNAKE_CASE`,
`MESSAGE_PASCAL_CASE`, `FIELD_LOWER_SNAKE_CASE`, `ONEOF_LOWER_SNAKE_CASE`,
`ENUM_PASCAL_CASE`, `ENUM_VALUE_UPPER_SNAKE_CASE`, `ENUM_VALUE_PREFIX` (values carry the
enum's name as prefix, so `Color.RED` is `COLOR_RED`), `SERVICE_PASCAL_CASE`,
`SERVICE_SUFFIX` (`Service`), `RPC_PASCAL_CASE`, `RPC_REQUEST_STANDARD_NAME` and
`RPC_RESPONSE_STANDARD_NAME` (`FooRequest`, `FooResponse`), `RPC_REQUEST_RESPONSE_UNIQUE`
(no sharing of request or response messages between RPCs, since they will diverge).

**Structure and wire economy** (`default`): `PACKAGE_DIRECTORY_MATCH`,
`PACKAGE_SAME_DIRECTORY`, `PACKAGE_VERSION_SUFFIX` (`strict` only),
`FIELD_NUMBERS_HOT_RANGE` (fields 1 to 15 cost one byte; a message with many fields and
the hot range spent on rarely-set ones is worth a note; keep this a `strict` rule, since
it needs judgement), `NO_DEPRECATED_FEATURES` (editions features marked deprecated),
`ONEOF_MEMBER_NOT_REPEATED_OR_MAP` is a compile error already, so skip; `MAP_VALUE_NOT_MESSAGE_FOR_NESTING`?
no, skip judgement calls that need the data.

**Documentation** (`strict`): `COMMENT_MESSAGE`, `COMMENT_FIELD`, `COMMENT_ENUM`,
`COMMENT_ENUM_VALUE`, `COMMENT_SERVICE`, `COMMENT_RPC`: leading comments on public
elements, read from the source info the compiler already collects.

**Editions**: `EDITION_RECOMMENDED` (proto3 files could move to the current edition;
`strict`), and the features lints protoc warns about already are passed through.

Every rule's check reads the frozen `Schema::File` plus the AST positions (through the
compiler's existing node-to-position mapping) and the file's source info for comments;
no rule re-parses. Rule implementations are one small class each under
`lib/protostar/lint/rules/`, registered in a table with their set memberships, so adding
a rule is one file and one line.

## What stays protoc-identical

`protostar compile` keeps printing protoc's one-line diagnostics by default; the corpus
tests that pin protoc's wording and order are untouched. The renderer is additive.

## Tests

- A golden test per rule: a `.proto` snippet that trips it and one that does not, with
  the rendered text pinned (plain, no colour) and the JSON pinned.
- The renderer: single-line and multi-line spans, two labelled spans, tabs in the source
  line, a diagnostic at end of file, and that the corpus's recorded protoc errors all
  render without raising (run every validation snippet and parser error case through
  the renderer).
- The codes catalogue test described above.
- Config loading, comment directives, `--except`, `--rules`, exit codes, `--format` for
  all three, `--fix` on a temp copy, and `lint` over a directory tree including a file
  with a parse error (lint still runs on the others, exit 2).
- Run `protostar lint` over `test/corpus/protobuf` with `--rules minimal` and record
  the count per rule in the report; Google's own test files violate plenty, which makes
  a fine smoke test, but nothing asserts on those counts.

## Out of scope for the first cut

Breaking-change detection against a previous descriptor set (`lint --against old.binpb`,
what `buf breaking` does); a language server; auto-fix for anything beyond the
unambiguous renames. Each is a brief of its own once this lands.
