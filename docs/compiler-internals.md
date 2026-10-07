# How the protostar compiler works

This document follows a `.proto` file through `Protostar::Compiler` from bytes to frozen
`Protostar::Schema::File` objects, and from there into generated Ruby. It names the real
classes and methods, shows the data that moves between stages, and explains why each stage
is built the way it is. The Schema construction, options and reflection APIs it relies on
are described on their own in `docs/schema-api.md`.

Every code sample's output in this document was produced by running the code in this
repository (Ruby 3.4.1, arm64 macOS, no YJIT). Nothing is paraphrased output.

"(as protoc does)" marks behaviour that is a deliberate port of protoc 36.2. Most of the
compiler is such a port. Where it deviates, the deviation is called out.

## Contents

1. What the compiler promises
2. The pipeline at a glance
3. The running example
4. The lexer
5. The parser and the AST
6. Loading files: `Run`
7. The linker
8. Name resolution and the first-component rule
9. What the parser and linker synthesise
10. Option interpretation
11. Aggregate option values: `TextFormat`
12. The bootstrap problem: compiling descriptor.proto with its own options
13. Drafts, the Schema objects and the translation to protoc's shape
14. Editions and feature resolution
15. The validator
16. Source info: spans, paths and comments
17. Diagnostics and error recovery
18. Retention stripping and the two pools
19. After the compiler: emitters
20. How it is verified against protoc
21. Performance
22. Known differences and sharp edges
23. File map

## 1. What the compiler promises

The brief (`llm/instructions/ws2-compiler.md`) is short to state and long to meet:

- For every file protoc accepts, produce a `Schema::File` whose translation to protoc's
  shape (`to_proto`) is, field for field and byte for byte, the `FileDescriptorProto` protoc
  36.2 writes. That includes custom options and, when asked for, `source_code_info` with
  protoc's exact paths, spans and comments.
- For every file protoc rejects, reject it with the same `file:line:col: message` lines, in
  the same order, including protoc's multiple errors per file.
- Warnings (unused imports, deprecated features, generic services) are warnings, as in
  protoc.

The design follows from that: instead of writing a protobuf compiler, the code ports
protoc's own front end function by function, so that edge cases come out the same without
being rediscovered one by one. The class names say which protoc component each file is a
port of.

The public surface is small:

```ruby
compiler = Protostar::Compiler.new(include_paths: ["proto"], pool: Protostar::Schema::Pool.new)
files  = compiler.compile(["foo/bar.proto"], source_info: true)  # Array<Schema::File>, imports first
files.last.to_proto                                              # its FileDescriptorProto message
compiler.diagnostics                                             # warnings of the last compile
```

(`compile_to_hashes` gave each file's `to_proto.to_h`; it is deprecated and goes away in 0.2.0.)

`compile` also takes `sources: {"name.proto" => text}` for in-memory files (used throughout
this document and the tests), `retain_options: true` (see section 18) and a private
`protoc_cli: false` switch (section 17).

## 2. The pipeline at a glance

| # | Stage | Class (file) | Input | Output | Port of |
|---|---|---|---|---|---|
| 1 | Lexing | `Compiler::Lexer` (`compiler/lexer.rb`) | source bytes | `Lexer::Token` stream, comments on request | `io/tokenizer.cc` |
| 2 | Parsing | `Compiler::Parser` (`compiler/parser.rb`) | tokens | `AST::File` + `SourceInfo::Location`s + parse errors | `compiler/parser.cc` |
| 3 | Loading | `Compiler::Run` (`compiler/run.rb`) | file names | ASTs in dependency order, pool lookups | the importer and CLI driver |
| 4 | Symbols and drafting | `Linker#setup_symbols`, `#build_file` with `SymbolTable` and `Schema::File.draft` | AST + pool | a drafted `Schema::File`, full names, source paths, symbol table, per-element checks | `DescriptorBuilder::BuildFile` (AddSymbol etc.) |
| 5 | Cross-linking | `Linker#cross_link` | AST + symbol table | resolved types and extendees, recorded on the drafted descriptors | `DescriptorBuilder::CrossLinkFile` |
| 6 | Options | `OptionInterpreter`, `TextFormat` | uninterpreted options + the linked draft | a `Schema::MessageValue` per element, set on the draft; rewritten source paths | `OptionInterpreter` |
| 7 | Resolve and freeze | `Schema::Draft::File#resolve`, `#freeze!` | the draft | frozen, shareable `Schema::File`: options objects, features, defaults | `DescriptorPool::BuildFile` |
| 8 | Validation | `Compiler::Validator` | built file + AST | more problems | `ValidateOptions` and the CLI checks |
| 9 | Reporting | `Run#report` | `Linker::Problem`s | `Compiler::Diagnostic`s | the error collector |
| 10 | Output | `Compiler#output_file`, `Retention.strip`, `Schema::Draft.copy` | pool files | stripped copies (what `compile` returns) | `compiler/retention.cc` |
| 11 | Emitting | `Compiler::Emitters::*` | `Schema::File`s | Ruby source, RBS, descriptor set bytes (through `to_proto`) | the code generators, `FileDescriptor::CopyTo` |

Stages 4 to 7 run inside one call to `Linker#link`. No stage hands a `FileDescriptorProto`-shaped
Hash to the next: the parse tree is translated into Schema descriptors as the linker meets
its elements, and protoc's shape appears only when a file is written out (`to_proto`). `Validator#validate` runs right after
it, still per file. `Validator.cli_checks` runs once over the files named on the command
line, after all of them are built.

## 3. The running example

Most sections use this file:

```proto
syntax = "proto3";
package shop;

// A thing for sale.
message Item {
  string name = 1; // shown to buyers
  optional int64 price_cents = 2;
  map<string, int32> stock = 3;
}
```

It is small but exercises three synthesis rules (a map entry, a synthetic oneof, json
names), comment attachment and name resolution.

## 4. The lexer

`Compiler::Lexer` is a byte-level port of protoc's `Tokenizer` (as protoc does). It works on
`source.b` and walks it one byte at a time with precomputed 256-entry lookup tables
(`LETTER`, `DIGIT`, `HEX`, `OCTAL`, `WHITESPACE`, ...), the same character classes protoc's
tokenizer uses.

### Token shape

`Lexer::Token` is a small class with keyword constructor and accessors for `type`, `text`,
`line`, `column` and `end_column`. It is mutable on purpose: like protoc's `Tokenizer`, the
lexer reuses one current token as it advances and copies it into `previous`.

| Field | Meaning |
|---|---|
| `type` | `:start` (before the first token), `:identifier`, `:integer`, `:float`, `:string`, `:symbol`, `:end`; `:whitespace` and `:newline` only when the parser asks for them |
| `text` | the exact source text: quotes and escapes included for strings, `0x1F` as written for integers |
| `line` | 0-based |
| `column` | 0-based; a tab advances to the next multiple of 8 (as protoc does) |
| `end_column` | 0-based column just after the token |

The lexer keeps two tokens, `current` and `previous`. The parser needs `previous` to end a
source span at the last token it consumed.

Tokens for the first lines of the example (`token.to_a`):

```
[:identifier, "syntax", 0, 0, 6]
[:symbol, "=", 0, 7, 8]
[:string, "\"proto3\"", 0, 9, 17]
[:symbol, ";", 0, 17, 18]
[:identifier, "package", 1, 0, 7]
[:identifier, "shop", 1, 8, 12]
[:symbol, ";", 1, 12, 13]
[:identifier, "message", 4, 0, 7]
[:identifier, "Item", 4, 8, 12]
[:symbol, "{", 4, 13, 14]
[:identifier, "string", 5, 2, 8]
[:identifier, "name", 5, 9, 13]
```

`Lexer#next` skips the comment on line 3 entirely. Comments are only collected when the
parser calls `next_with_comments` (below).

### Literals are kept as text

The lexer decides token boundaries and types, but does not convert values. Conversion
happens where the parser knows what it wants, through class methods that port protoc's
helpers:

| Method | Port of | Notes |
|---|---|---|
| `Lexer.parse_integer(text, max)` | `Tokenizer::ParseInteger` | decimal, `0x` hex, leading-zero octal; nil above `max` |
| `Lexer.parse_float(text)` | `Tokenizer::ParseFloat` | `1.`, `.5`, `1e10`, exponent signs |
| `Lexer.parse_string(text, out)` | `Tokenizer::ParseStringAppend` | every escape: `\a \b \f \n \r \t \v \\ \' \" \?`, octal, `\x`, `\u`, `\U`, surrogate pairs |
| `Lexer.float_text?(text)` | `TryParseFloat`'s strtod check | used for integers too large for uint64 |

Keeping the text matters for two reasons. The same token means different things in different
places (an integer literal is an int32 field number, a uint64 default, or a double option
value), and range errors must use the limit of the place it appears, with protoc's message
("Integer out of range."). Default values are also stored in the descriptor as text
(section 9), so the text has to survive.

### Errors

The lexer reports through a callback `(line, column, message)` and keeps going, with
protoc's messages: "Need space between number and identifier.", "Numbers starting with
leading zero must be in octal.", "Multiline strings are not allowed. Did you miss a \"?.",
"\"/*\" inside block comment.  Block comments cannot be nested.", "Invalid control
characters encountered in text.", and so on. A UTF-8 BOM is accepted at the start; any
other leading `0xEF` is an error (as protoc does).

### Comments: `next_with_comments` and `CommentCollector`

`next_with_comments(prev_trailing, detached, next_leading)` is protoc's
`Tokenizer::NextWithComments` (as protoc does). It advances one token and, along the way,
sorts the comments it crosses into three buckets:

- a comment that starts on the same line as the previous token, or on the next line and is
  followed by a blank line or a closing `}`, becomes the previous token's trailing comment;
- comments separated from the next token by a blank line become detached comments;
- the comment block directly before the next token becomes its leading comment.

`Lexer::CommentCollector` is the C++ class of the same name, including its destructor logic
(`finish`). The parser decides which declaration those buckets belong to (section 16).

## 5. The parser and the AST

`Compiler::Parser` is a hand-written recursive-descent parser that follows `parser.cc`
function by function (as protoc does). The method names map one to one:
`parse_top_level_statement` is `ParseTopLevelStatement`, `parse_message_field_no_label`
is `ParseMessageFieldNoLabel`, `parse_uninterpreted_block` is `ParseUninterpretedBlock`,
and so on. The error messages are protoc's, character for character.

The parser does three jobs at once, as protoc's does:

1. builds an `AST::File` holding what protoc's parser puts in a `FileDescriptorProto`
   before linking: names as written, options uninterpreted;
2. records source locations through `SourceInfo::Recorder` (section 16);
3. records, on every node, the start positions the later stages report errors against.

### AST node shapes

All nodes are plain Ruby objects in `Compiler::AST`, with `positions`, a Hash of position
kind to `[line, column]`. They have no `to_h`: the parse tree is not handed on as a hash.
The parser tests, which compare it with what `parser_unittest.cc` expects, derive protoc's
pre-link `FileDescriptorProto` from it in `test/support/ast_hash.rb`.

| Node | Attributes from the source | Attributes set by the linker |
|---|---|---|
| `AST::File` | `name package syntax edition options dependency public_dependency weak_dependency option_dependency message_type enum_type service extension import_positions locations` | `full_name path` |
| `AST::Message` | `name options visibility field nested_type enum_type extension_range extension oneof_decl reserved_range reserved_name` | `parent index full_name path` |
| `AST::Field` | `name number label type type_name extendee default_value json_name oneof_index proto3_optional options` | `parent index extension full_name path` |
| `AST::Oneof` | `name options` | `parent index full_name path` |
| `AST::Range` | `start end options` (extension ranges and reserved ranges) | `parent index full_name path` |
| `AST::Enum` | `name options visibility value reserved_range reserved_name` | `parent index full_name path` |
| `AST::EnumValue` | `name number options` | `parent index full_name path` |
| `AST::Service` | `name options rpcs` | `index full_name path` |
| `AST::Method` | `name input_type output_type options client_streaming server_streaming` | `parent index full_name path` |
| `AST::Options` | `uninterpreted` (Array of `AST::Option`), `known` (options the parser sets itself, only `map_entry`) | |
| `AST::Option` | `name` (Array of `[part, is_extension]`), `value_kind`, `value` | |

`AST::Option#value_kind` is one of `:identifier_value`, `:positive_int_value`,
`:negative_int_value`, `:double_value`, `:string_value`, `:aggregate_value`, the fields of
protoc's `UninterpretedOption`. `display_name` renders the name the way protoc prints it in
errors, `(a.b).c`.

The position kinds are the `ErrorLocation` values protoc's `DescriptorPool` reports
against: `:name`, `:number`, `:type`, `:extendee`, `:default_value`, `:option_name`,
`:option_value`, `:input_type`, `:output_type`, `:editions`, `:other` (as protoc does; the
parser fills them through `Recorder#record_legacy`, protoc's `SourceLocationTable`).
Imports are tracked separately in `AST::File#import_positions`, keyed by the imported name.

### The example as an AST

`AstHash.file(Parser.new(src).parse("shop.proto"))` (the test support's view of the tree):

```ruby
{name: "shop.proto",
 package: "shop",
 message_type:
  [{name: "Item",
    field:
     [{name: "name", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_STRING},
      {name: "price_cents",
       number: 2,
       label: :LABEL_OPTIONAL,
       type: :TYPE_INT64,
       oneof_index: 0,
       proto3_optional: true},
      {name: "stock",
       number: 3,
       label: :LABEL_REPEATED,
       type_name: "StockEntry"}],
    nested_type:
     [{name: "StockEntry",
       field:
        [{name: "key", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_STRING},
         {name: "value",
          number: 2,
          label: :LABEL_OPTIONAL,
          type: :TYPE_INT32}],
       options: {map_entry: true}}],
    oneof_decl: [{name: "_price_cents"}]}],
 syntax: "proto3"}
```

Note what is already there and what is not:

- The map entry message `StockEntry` and the synthetic oneof `_price_cents` already exist.
  protoc's parser creates them, so this parser does too (section 9).
- `stock` has `type_name: "StockEntry"` and no `type`: the parser does not know yet whether
  a name refers to a message or an enum. That is the linker's job.
- No `json_name` anywhere: protoc's parser only records an explicit `json_name`.

And `positions` on `price_cents`:

```ruby
{type: [6, 11], name: [6, 17], number: [6, 31]}
```

### Things the parser does that are easy to miss

- **Syntax and editions.** `parse_syntax_identifier` accepts `syntax = "proto2" | "proto3"`
  and `edition = "..."` for the editions in `Schema::Features::EDITIONS`, rejecting
  `"proto2"`, `"proto3"` and unknown values as editions. A file without either is proto2,
  silently (protoc 36.2 prints nothing either). `require_syntax: true` is only for the
  `parser_unittest.cc` cases that turn it on.
- **Labels by syntax.** In proto3 and editions an unlabelled field is `LABEL_OPTIONAL`; in
  proto2 it is "Expected \"required\", \"optional\", or \"repeated\"." A proto3 `optional`
  sets `proto3_optional`. In editions `optional` and `required` are parse errors with
  protoc's long messages, and so is `group`.
- **`EDITION_UNSTABLE` types.** In that edition, `int32` means `sfixed32` and the varint
  types are spelled `varint32`, `zigzag32`, and so on (`UNSTABLE_TYPES`), with an error for
  the old spellings (as protoc does).
- **`max` in ranges.** `extensions 100 to max` cannot know the maximum until the message is
  parsed, because `message_set_wire_format` raises it to `INT32_MAX`. The parser stores a
  sentinel and `adjust_max_ranges` fixes it at the closing brace (as protoc does).
- **Extension range options are copied.** `extensions 1 to 5, 10 to 20 [ (opt) = 1 ];`
  attaches the options to the first range, copies them to the others, and duplicates the
  source locations of the options for each range with the range index rewritten (as protoc
  does).
- **Parse-time validation.** Two checks live in the parser because protoc's parser has them:
  `map_entry` set by hand, and `allow_alias = false` or an `allow_alias = true` with no
  aliases (`validate_message`, `validate_enum`).
- **Nesting limit.** 32 levels of nested messages, then "Reached maximum recursion limit for
  nested messages." (as protoc does).
- **Visibility.** `export` and `local` before `message` and `enum` are only recognised from
  edition 2024 on.
- **Imports.** `import public`, `import weak` and, from edition 2024, `import option` (which
  must come after plain imports) are recorded in `dependency`, `public_dependency`,
  `weak_dependency` and `option_dependency`.

### Aggregate option values stay text

`option (opt) = { a: 1 b { c: "x" } };` cannot be parsed into values yet, because the parser
does not know the option's type. `parse_uninterpreted_block` turns on the lexer's
`report_whitespace` and `report_newlines` modes and rebuilds the text between the braces
from the tokens, reinserting newlines and column padding, which reproduces protoc's
`aggregate_value` string exactly (as protoc does; `parser_unittest.cc` has seven cases for
this whitespace alone). The linker parses it later (section 11).

### Error recovery

When a statement fails, the parse method returns false and its caller calls
`skip_statement`: skip tokens until a `;` (end of statement) or a `{ ... }` block has been
consumed, or a `}` is next. Inside messages, enums, services and `extend` blocks the loop
then continues with the next statement. At top level an unmatched `}` is reported and
skipped (as protoc does). This is why one file can produce several parse errors, and why
they are the same ones protoc reports (see section 17 for an example).

A file with any parse error is not linked. Its importers see it as missing.

## 6. Loading files: `Run`

`Compiler#compile` creates one `Compiler::Run` per call. `Run#load(name)` is a depth-first
loader that mirrors protoc's importer (as protoc does):

1. Return the cached result if this name was already handled in this run.
2. If the pool already has the file, reuse it (files are compiled once per pool).
3. If the name is on the stack of files being loaded, report "File recursively imports
   itself: a.proto -> b.proto -> a.proto" at the import statement and fail.
4. Read the source: `sources:` first, then `Compiler#resolve`, which tries each include path
   in order and the bundled `lib/protostar/compiler/include` last.
5. Parse. Report parse errors and warnings. Stop if there were errors.
6. Load every `dependency` and `option_dependency` recursively; collect the ones that failed
   as `missing`.
7. Link (`Linker#link`) and validate (`Validator#validate`), report their problems, and on
   success add the built file to the pool.

Imports are therefore always built before their importers, and diagnostics come out in the
order protoc prints them. `Run#call` returns the files in dependency order (imports first),
listing each once. After all named files are built, `Validator.cli_checks` runs the checks
protoc's command line adds (section 15).

The pool (`Schema::Pool`) outlives the run: a second `compile` on the same compiler reuses
everything it already holds. A changed file needs a fresh pool.

## 7. The linker

`Compiler::Linker` corresponds to protoc's `DescriptorBuilder`. `Linker#link` runs its
phases in protoc's order:

```ruby
def link
  setup_edition
  setup_symbols
  build_file
  cross_link
  suggest_field_numbers
  unless errors?
    interpret_options
    build_schema unless errors?
  end
  @file
end
```

| Phase | What it does | protoc counterpart |
|---|---|---|
| `setup_edition` | maps `syntax`/`edition` to an edition (`:EDITION_PROTO2`, `:EDITION_PROTO3`, or the file's), checks it against the supported range | `BuildFileImpl` edition checks |
| `setup_symbols` | finds each import in the pool, reports duplicates and missing imports, builds the `SymbolTable` with import visibility and the unused-import candidates | `BuildFileImpl` dependency loop |
| `build_file` | registers the package, drafts the file (`Schema::File.draft`) and every message, field, oneof, range, enum, value, service and method in it, assigns `full_name`, `path`, `parent` and `index` to every node, registers every symbol (`add_symbol`) with its drafted descriptor, runs the per-element checks that need no names resolved, and queues options as `Pending`; then seals the draft's lookup tables | `BuildMessage`, `BuildFieldOrExtension`, `BuildEnum`, ... |
| `cross_link` | resolves every type name, extendee, rpc input and output and records the result on the drafted descriptor; checks kinds, enum defaults, oneof contiguity, duplicate field numbers | `CrossLinkFile` and friends |
| `suggest_field_numbers` | adds "Suggested field numbers for X: ..." after number errors | `SuggestFieldNumbers` |
| `interpret_options` | links and resolves the draft without options, runs `OptionInterpreter` (section 10) against it, sets each element's options on the draft, and rewrites option source paths | `OptionInterpreter` |
| `build_schema` | gives the draft its source info, resolves it again (options objects, features, defaults) and freezes it | the pool build |

`Linker#descriptor_of(node)` answers the descriptor drafted for an AST node; the validator
reads descriptors through it.

The drafting happens in `build_file` even though the file may still fail: a duplicate
symbol is reported by the symbol table with protoc's message, and the draft only remembers
it (`link` would refuse it). A file with errors is never linked or frozen.

Each problem is recorded as a `Linker::Problem`, a frozen object made with keywords:

```ruby
Problem.new(severity: :error, node: field, location: :number, message: "...")
```

`node` is the AST node and `location` the position kind protoc reports the error at
(`:name`, `:number`, ...), or `:import` with `import` naming the file; `error?` tells
errors from warnings. Positions are only
looked up when `Run` turns problems into diagnostics (section 17). That separation lets the
linker and validator report errors "against the field's number" exactly where protoc does,
without carrying positions around.

### Checks in `build_file`

These need only the AST, the symbol table and the drafted structure, so they run before
resolution, in protoc's order: "is already defined" (in the same scope, in another file, or as a package), the enum
value C++ scoping note ("enum values are siblings of their type, not children of it"),
positive field and extension numbers, the 536870911 maximum, extension and reserved ranges
that are empty, overlap each other or contain fields, reserved names used or repeated,
required extensions, defaults on repeated fields, boolean and bytes default syntax, empty
enums. Range overlap and "uses reserved number" checks also feed `hint`, which drives
`suggest_field_numbers` (as protoc does).

### Checks in `cross_link`

`cross_link_field` resolves the extendee ("is not a message type", "does not declare N as
an extension number"), then the type name, deciding message or enum when the parser could
not ("is not a type", "is not an enum type", enum default exists in the enum). What a name
resolved to goes straight onto the drafted field (`Draft::File#__resolve_type`); the draft's
own `link` then leaves the field alone instead of resolving the name a second time. It then
records `[holder, number]` and reports "Field number N has already been used in \"X\" by
field \"y\". Next available field number is K." (as protoc does, including the next
available number computation). An extension number used by another file in the pool is a
warning (as protoc does). `cross_link_message` reports non-contiguous oneof members and
empty oneofs.

`visible?` implements edition 2024 symbol visibility: a type marked `local`, or local by
`default_symbol_visibility`, cannot be used from another file.

## 8. Name resolution and the first-component rule

### Why the compiler has its own symbol table

`Schema::Resolver` (WS1) implements protoc's lookup over built `Schema::File`s. The linker
cannot use it directly: it resolves names in the file being compiled while that file is
still a draft whose names are unresolved, and it must produce protoc's failure messages,
which need a pool-wide view ("seems to be defined in ..., which is not imported"). So
`Compiler::SymbolTable` implements the same rule over two sources: `local`, the file being
linked, whose symbols are registered as they are drafted, and the pool's descriptors.

A `SymbolTable::Symbol` is a frozen object with `kind`, `full_name`, `file_name`, `object`
and `local?`. `kind` is `:message`, `:enum`, `:enum_value`, `:field`, `:oneof`, `:service`,
`:method` or `:package`. `object` is the `Schema` descriptor either way: drafted, for the
file being linked, built, for the pool's. Reading a local symbol and a pool symbol is the
same code; the checks that once read an AST node for local symbols (`extension_number?`,
the enum values of an enum default) and a descriptor for the others now read descriptors
only. Package names are symbols too: `add_package` registers
`a.b.c`, `a.b` and `a` (as protoc does), which is how a message named `a` clashes with
package `a.b`.

### Lookup methods

| Method | protoc | Behaviour |
|---|---|---|
| `find_any(name)` | | any symbol, no visibility |
| `find_not_enforcing_deps(name)` | `FindSymbolNotEnforcingDeps` | any symbol; marks its file's import as used |
| `find(name)` | `FindSymbol` | visible symbols only: this file, direct imports and their `import public` chains, and fields from `import option` files; on failure sets `undeclared_file` |
| `lookup(name, relative_to, types_only:)` | `LookupSymbolNoPlaceholder` | the scoping rule below |

### The rule

A name with a leading dot is fully qualified: `find(name[1..])`.

Otherwise only the **first component** of the name is searched for, starting in the
innermost scope and walking outward. `relative_to` is the full name of the element doing
the lookup (a field's full name, say `pkg.Outer.inner`), and each step cuts its last
component: `pkg.Outer.Inner`, then `pkg.Inner`, then `Inner`.

- If the name has one component, the first hit wins, except that with `types_only` a hit
  that is not a message or enum is skipped and the search continues outward. This is how
  `optional Bar Bar = 1;` resolves the type `Bar` instead of the field `Bar`.
- If the name has several components and the first one is found as something that can
  contain names (a message, enum, service or package), the **whole** name must resolve
  under that scope. If it does not, the lookup fails without looking further out (as protoc
  does). A first component that cannot contain names (a field, for instance) is skipped.

That second point produces one of protoc's most confusing errors, reproduced exactly:

```proto
syntax = "proto2";
message Bar { message Baz {} }
message Foo {
  message Bar {}
  optional Bar.Baz baz = 1;
}
```

```
fc.proto:5:12: "Bar.Baz" is resolved to "Foo.Bar.Baz", which is not defined. The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., ".Bar.Baz") to start from the outermost scope.
```

`Bar` is found first as `Foo.Bar`, so `Bar.Baz` must be `Foo.Bar.Baz`, which does not
exist; the top-level `Bar.Baz` is never considered.

File-level options resolve relative to `"#{package}.dummy"`, so that cutting the last
component leaves the package (as protoc does, with the same `.dummy` trick).

### Failure messages

`not_defined_messages` builds protoc's `AddNotDefinedError` output from what the last lookup
left behind: plain "\"X\" is not defined.", the "seems to be defined in" message when the
symbol exists in a file that is not imported, or the "is resolved to" message above.

```
c.proto:1:50: "a.Thing" seems to be defined in "a.proto", which is not imported by "c.proto".  To use it here, please add the necessary import.
```

(Here `c.proto` imports `b.proto`, which imports `a.proto` without `public`, so `a.Thing`
is in the pool but not visible.)

### Unused imports

`SymbolTable#unused` starts as the direct imports of a file named on the command line that
are not public and have no public imports of their own. Every successful
`find_not_enforcing_deps` removes the symbol's file. Whatever is left becomes "Import x is
unused." warnings (as protoc does, for named files only).

### Agreement with `Schema::Resolver`

The compiler records what it resolved on the draft, so `Schema::Resolver` is not run over
compiled files; it resolves names for drafts nobody resolved, those of the DSL and
`File.from_proto`. To make sure the two implementations of the rule agree,
`test/compiler/resolver_test.rb` writes WS1's resolver cases as `.proto` sources, compiles them, and asserts `Schema::Resolver.resolve(written_name, ...)` returns the same
descriptor the compiler picked.

## 9. What the parser and linker synthesise

protoc's descriptors contain things nobody wrote. All of them are produced in the same
place protoc produces them, so their order and source locations match. The naming rules
are the draft API's (`Schema::Draft.map_entry_name`, `.synthetic_oneof_names`,
`.group_field_name`, `Schema.json_name`): the parser expands its tree with them, and the DSL
and hand-written drafts get the same expansion from `map`, `optional:` and `group`.

### Map entries (parser, as protoc does)

`map<string, int32> stock = 3;` becomes a repeated field of type `StockEntry` plus a nested
message, in `Parser#generate_map_entry`:

- the name is `Schema::Draft.map_entry_name`: the field name in CamelCase (underscores
  dropped, the next letter upcased) plus `Entry`;
- the entry gets `options.known[:map_entry] = true`, `key = 1` and `value = 2`, both
  `LABEL_OPTIONAL`;
- the entry is appended to the enclosing message's `nested_type` at the point the field is
  parsed, which fixes its index among hand-written nested types;
- the field's `features` options and, for string keys or values, `enforce_utf8`, are copied
  onto the key and value fields as uninterpreted options, so they are interpreted like any
  other option later.

The parser also refuses map fields in oneofs, with labels, or as extensions. The validator
checks the rest (key types, enum values starting at zero, that an entry type is not used
by hand, and "Expanded map entry type X conflicts with an existing nested message type.").

### Synthetic oneofs (parser, as protoc does)

For every proto3 `optional` field, `Parser#generate_synthetic_oneofs` appends a oneof after
the real ones, named by `Schema::Draft.synthetic_oneof_names`: `_` plus the field name, and
if that name collides with a field or oneof, `X` is prepended until it does not: a field `__foo` next to a oneof `_foo` gets `X_foo`
(this is `parser_unittest.cc`'s case). `oneof_index` points at it and `proto3_optional` is
set. `Schema::Oneof#synthetic?` is true for these, and `Field#real_oneof` skips them.

### Groups (parser, as protoc does)

`optional group Result = 1 { ... }` creates a nested message `Result` and a field named
`result` (`Schema::Draft.group_field_name`: the name lower-cased) of type `TYPE_GROUP` whose
`type_name` is `Result`. The nested message's source locations are built from the field's
recorder, as protoc does. Group names must start with a capital letter.

### json_name (the draft, as protoc does)

A field drafted without an explicit `json_name` gets `Schema.json_name(name)` (underscores
dropped, the letter after each upcased: `price_cents` becomes `priceCents`), and `to_proto`
writes `json_name` for every field, as protoc's `CopyTo` does.

### Default values (parser and linker, as protoc does)

`FieldDescriptorProto.default_value` is a string, and protoc's text is canonical, not what
the user wrote. The parser builds it in `parse_default_assignment`:

| Type | Stored as |
|---|---|
| integers | the parsed number, sign included (`0x10` becomes `"16"`), range-checked for the type |
| `float`, `double` | `Compiler.simple_dtoa` at parse time, then `simple_ftoa` (float) or `simple_dtoa` (double) again in `Linker#default_text` as the field is drafted; `inf`, `-inf`, `nan` spelled out |
| `bool` | `"true"` or `"false"` |
| `string` | the decoded string |
| `bytes` | `Compiler.c_escape` of the decoded bytes (absl's `CEscape`: `\n`, `\"`, octal for the rest) |
| enum | the identifier |

`simple_dtoa` is protoc's `SimpleDtoa`: `%.15g` unless that does not read back as the same
double, then `%.17g`. `simple_ftoa` does the same with `%.6g`/`%.9g` over the float32 value.

When the parser does not yet know the type (a `type_name` that might be an enum), it keeps
the raw token text, and `cross_link_field` validates it once the type is known.

### The example after linking

`compile(["shop.proto"], sources: ...).last.to_h`, which is `to_proto.to_h`: the built file
translated to protoc's shape, as a Hash for reading:

```ruby
{name: "shop.proto",
 package: "shop",
 message_type:
  [{name: "Item",
    field:
     [{name: "name",
       number: 1,
       label: :LABEL_OPTIONAL,
       type: :TYPE_STRING,
       json_name: "name"},
      {name: "price_cents",
       number: 2,
       label: :LABEL_OPTIONAL,
       type: :TYPE_INT64,
       oneof_index: 0,
       json_name: "priceCents",
       proto3_optional: true},
      {name: "stock",
       number: 3,
       label: :LABEL_REPEATED,
       type: :TYPE_MESSAGE,
       type_name: ".shop.Item.StockEntry",
       json_name: "stock"},
     ...],
    nested_type: [{name: "StockEntry", ..., options: {map_entry: true}}],
    oneof_decl: [{name: "_price_cents"}]}],
 syntax: "proto3"}
```

(The `StockEntry` fields are elided; they gained `json_name: "key"` and `json_name: "value"`.)
`type_name` is now fully qualified with a leading dot, `type` is filled in, `json_name` is
everywhere, and proto2's `syntax` would be omitted entirely (as protoc does).

## 10. Option interpretation

Every `option` statement and `[...]` field option is still an `AST::Option` when linking
starts. `build_file` queues every element that has options as a `Linker::Pending`, a frozen
object with `node`, `kind`, `name_scope`, `path` and `options` (the node's uninterpreted
options).

`kind` picks the options message (`Linker::OPTIONS_TYPES`: `:file` is
`google.protobuf.FileOptions`, `:field` is `google.protobuf.FieldOptions`, and so on).
`name_scope` is the scope custom option names are resolved in. `path` is the source path of
the element's `options` field. For a small file:

```proto
syntax = "proto3";
option java_package = "x.y";
message M { int32 a = 1 [deprecated = true]; }
```

the pending list, as `[kind, name_scope, path, option names]`, is:

```ruby
[[:field, "M.a", [4, 0, 2, 0, 8], ["deprecated"]],
 [:file, ".dummy", [8], ["java_package"]]]
```

### Two passes

`OptionInterpreter#run` interprets each element's options twice, as protoc does:

1. a pass over the options whose first name part is not an extension (`deprecated`,
   `java_package`, `features.field_presence`, ...);
2. a callback into `Linker#check_features` with the `features` each element set, which
   reports "Features are only valid under editions." and unknown feature values before any
   custom option is looked at;
3. a pass over the custom options (`(my.opt).x`).

Within an element, interpretation stops at the first failing option (as protoc does). So a
file with two broken file options reports only the first.

### Resolving the option name

`interpret_single` walks the name parts. A plain part is looked up in the current options
message's `fields_by_name`. A parenthesised part is resolved with `SymbolTable#lookup`
relative to `name_scope` and must be an extension field of the current message. Each
intermediate part must be a singular message field, whose type becomes the message for the
next part. The errors are protoc's: "Option \"(nope)\" unknown. Ensure that your proto
definition file imports the proto which defines the option (i.e. via import option after
edition 2024).", "is an atomic type, not a message.", "is a repeated message. Repeated
message options must be initialized using an aggregate value.", "is not a field or
extension of message", and the "is resolved to" variant of the first-component error.

### Entries, then values

The interpreter does not build the options value as it goes. Each option becomes an **entry**
`[Schema::Field, value]`, with intermediate message fields wrapped around it: `(limits).max
= 10` becomes `[limits_field, [[max_field, 10]]]`. Entries for one element accumulate in a
list. This mimics how protoc works: it serialises every interpreted option into the options
message's unknown fields and lets the proto parser merge them at the end. The consequences
carry over:

- `already_set?` is protoc's `ExamineIfOptionIsSet`: setting a singular field twice is an
  error, even through different paths. `option (lim).max = 1; option (lim) = { max: 2 };`
  gives "Option \"(lim)\" was already set." (because the aggregate sets all of `(lim)`
  after a sub-field was set). The opposite order is allowed, and the sub-field is merged
  into the aggregate.
- `OptionInterpreter#fold` turns the entries into a `Schema::MessageValue` with
  parse-merge semantics: repeated fields append, singular message fields merge, scalars
  take the last value. Known fields go under their name as a Symbol, extensions under their
  `Schema::Field`, which for an extension declared in the same file is the drafted
  descriptor that ends up in the frozen file. The linker sets the value on the draft as
  that element's options (`Draft::File#set_options`).

### Values

`option_value` converts the `AST::Option` value by the field's type, with protoc's range
checks and messages ("Value out of range, -2147483648 to 2147483647, for int32 option
\"...\".", "Value must be quoted string for string option", "Value must be identifier for
enum-valued option", ...). Some details ported on purpose:

- `float` options hold the float32-rounded value (`Schema::DefaultValue.to_float32`).
- Enum values are looked up as siblings of the enum type, C++ style, so naming a value of a
  different enum in the same scope gives protoc's "This appears to be a value from a sibling
  type." For enums from the built-in descriptor.proto (section 12) the value is looked up
  directly.
- Enum values are stored as the Symbol of the first value with that number, so aliases
  normalise.
- Message-typed options require an aggregate value, parsed by `TextFormat` (next section).

### Source paths

As each option is interpreted, `interpreted_paths` maps its uninterpreted source path to the
path of the field it set, with extension field numbers and, for repeated fields, an index.
For the small file above:

```ruby
{[4, 0, 2, 0, 8, 999, 0] => [4, 0, 2, 0, 8, 3], [8, 999, 0] => [8, 1]}
```

`3` is `FieldOptions.deprecated`, `1` is `FileOptions.java_package`. Section 16 shows how
the locations are rewritten.

### A worked example with a custom option

```proto
syntax = "proto2";
package acme;
import "google/protobuf/descriptor.proto";

message Limits { optional int32 max = 1; repeated string tags = 2; }

extend google.protobuf.MessageOptions {
  optional Limits limits = 50001;
}

message Order {
  option (limits) = { tags: "a" tags: "b" };
  option (limits).max = 10;
  option deprecated = true;
  optional int32 qty = 1 [default = 1, json_name = "q"];
}
```

What the parser stored for `Order`'s options:

```ruby
{uninterpreted_option:
  [{name: [{name_part: "limits", is_extension: true}],
    aggregate_value: " tags: \"a\" tags: \"b\" "},
   {name:
     [{name_part: "limits", is_extension: true},
      {name_part: "max", is_extension: false}],
    positive_int_value: 10},
   {name: [{name_part: "deprecated", is_extension: false}],
    identifier_value: "true"}]}
```

What the descriptor ends up with:

```ruby
order.options
# => #<Protostar::Schema::MessageOptions deprecated: true, (acme.limits): #<Protostar::Schema::MessageValue tags: ["a", "b"], max: 10>>
order.options.deprecated?                # => true
order.options.extension("acme.limits")   # => #<Protostar::Schema::MessageValue tags: ["a", "b"], max: 10>
```

Known options come first in statement order, then custom options in statement order, as
the two passes interpret them. `docs/schema-api.md` describes the options objects.

`default` and `json_name` are not options at all: the parser stores them in the field
directly, as protoc's does, and `order.field("qty").to_h` is
`{name: "qty", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32, default_value: "1", json_name: "q"}`.

## 11. Aggregate option values: `TextFormat`

`Compiler::TextFormat` is a deliberately small slice of protoc's `text_format.cc`, just
enough for aggregate option values, kept private (the full text-format parser lives
elsewhere, in WS5). It reuses the `Lexer` over the aggregate text and produces entries in
the same `[field, value]` form as the interpreter, so `fold` treats both the same way.

It handles:

- `name: value` and `name { ... }` / `name < ... >`, with `:` optional before messages;
- `[ext.name]: value` extensions, resolved through the `SymbolTable` relative to the
  message type, and MessageSet items named by their message type;
- repeated fields as repeated `name: v` and as lists `name: [a, b]`;
- group fields by their message type name (`Result { }` for field `result`);
- scalar parsing with protoc's text-format rules: booleans as `true`, `True`, `t`, `1`;
  `inf`, `infinity`, `nan` for floats (case-insensitive); hex and octal rejected for floats;
  open enums accepting unknown numbers; closed enums not;
- duplicate singular fields ("Non-repeated field \"x\" is specified multiple times.") and
  two members of one oneof;
- `google.protobuf.Any` written as `[type.googleapis.com/pkg.Msg] { ... }`: the inner
  message is parsed against `pkg.Msg`, folded, and encoded to wire bytes with
  `MessageValue#encode`, then stored as the Any's `type_url` and `value` (as protoc does,
  since that is what serialising the Any would contain).

Errors are wrapped by the interpreter as "Error while parsing option value for \"x\": ...".

Not implemented (listed in the WS2 report): `#` comments inside aggregates,
`allow_f_after_float`, and field numbers instead of names.

## 12. The bootstrap problem: compiling descriptor.proto with its own options

`google/protobuf/descriptor.proto` defines `FileOptions`, `FieldOptions` and the rest, and
also uses them: `option java_package = "com.google.protobuf";` at the top, and on its own
fields `[retention = RETENTION_SOURCE]`, `targets`, `feature_support` and
`edition_defaults`. When compiling it, the options messages needed to interpret its options
do not exist yet in any pool.

The interpreter solves this by reading option types from `Schema::Message`s, and for the
file being compiled those are its own drafted descriptors. Before interpreting, the linker
links the draft (every name is already resolved onto it) and resolves it once with no
options, which gives every descriptor its structural features (`packed?` needs them when an
`Any` in an aggregate is encoded):

```ruby
def interpret_options
  ...
  @draft.resolve(@pool)
  @interpreter = OptionInterpreter.new(self, @pool, @options_fallback)
  options = @interpreter.run(@pending) { |features| check_features(features) }
  options.each { |node, value| @draft.set_options(descriptor_of(node), value) }
  ...
```

Since local symbols hold drafted descriptors, a lookup that lands in the file being
compiled already answers with the descriptor the interpreter needs
(`OptionInterpreter#schema_of` is `symbol.object`). This works the same for
descriptor.proto's own options and for a file that declares a custom option and uses it
in the same file, and the extension descriptor the options are keyed by is the one the
frozen file will hold.

`options_type(name)` decides which `FileOptions` (say) to interpret against, the way protoc
chooses:

1. the one visible to the file being compiled: its own (descriptor.proto itself) or the
   pool's, found with `find_not_enforcing_deps`;
2. otherwise the one compiled into protoc. Ours is `Compiler#builtin_options_type`, a
   private `Compiler.new(include_paths: []).compile(["google/protobuf/descriptor.proto"])`
   of the bundled copy, memoised per `Compiler` instance.

The second case is common: a proto3 file with `option java_package = "x";` that never
imports descriptor.proto still has its option interpreted, against the built-in copy. And
compiling that built-in copy goes through the same pipeline, which in turn finds its
options messages locally (case 1), so there is no recursion.

The result for one of descriptor.proto's own fields, compiled with `retain_options: true`,
as `field.to_h` (field number order, the way `to_proto` writes it):

```ruby
{name: "field_presence",
 number: 1,
 label: :LABEL_OPTIONAL,
 type: :TYPE_ENUM,
 type_name: ".google.protobuf.FeatureSet.FieldPresence",
 json_name: "fieldPresence",
 options:
  {retention: :RETENTION_RUNTIME,
   targets: [:TARGET_TYPE_FIELD, :TARGET_TYPE_FILE],
   edition_defaults:
    [{edition: :EDITION_LEGACY, value: "EXPLICIT"},
     {edition: :EDITION_PROTO3, value: "IMPLICIT"},
     {edition: :EDITION_2023, value: "EXPLICIT"}],
   feature_support: {edition_introduced: :EDITION_2023}}}
```

and as the options object (statement order):

```ruby
#<Protostar::Schema::FieldOptions retention: :RETENTION_RUNTIME, targets: [:TARGET_TYPE_FIELD, :TARGET_TYPE_FILE],
  feature_support: #<Protostar::Schema::MessageValue edition_introduced: :EDITION_2023>,
  edition_defaults: [#<Protostar::Schema::MessageValue edition: :EDITION_LEGACY, value: "EXPLICIT">, ...]>
```

The cost is one extra feature resolution of the draft, not a second build: until this
workstream the file was built from a hash twice (a structural build without options, then
the final one), and three times when `compile` returned the stripped copy (section 18).

One rule follows protoc here: a file may not use a feature extension it defines itself
("Feature \"...\" can't be used in the same file it's defined in.").

## 13. Drafts, the Schema objects and the translation to protoc's shape

### Drafting

The linker builds its result through `Schema::File.draft` (described in full in
`docs/schema-api.md`). Each draft call creates the real descriptor at once; the draft only
keeps what it needs to go on describing. A draft is finished in three calls:

1. `link(pool)`: finds the dependencies in the pool, completes the lookup tables
   (`fields_by_number`, `fields_by_name`, `extension_ranges`, `all_messages`, ...) and
   resolves the names nobody resolved yet through `Schema::Resolver` (for compiled files,
   none: `cross_link` resolved them onto the draft);
2. `resolve(pool)`: builds each descriptor's options object (`Schema::FieldOptions` and
   so on) from what it was given, resolves features (section 14) and parses defaults
   (`Field#default`); it may run again after options change, which is what the compiler
   does (section 12);
3. `freeze!`: `Freezer.deep_freeze` then `Ractor.make_shareable`, and returns the
   `Schema::File` the draft was building all along.

The last step has a story: `Ractor.make_shareable` on a graph with back references (every
field points at its message, which points at all its fields) went quadratic, 1.4 s for
`unittest.proto`. Freezing everything first and then calling `make_shareable` lets it
confirm the graph in one pass, under 4 ms.

A draft checks shape, not semantics (duplicate numbers and the like are the compiler's
job). If it raises on what the linker drafted, that is a compiler bug; `build_schema`
turns it into a position-less error rather than crashing.

### The `Schema` objects

For the example, `file.find_message("shop.Item")` and its fields:

```ruby
#<Protostar::Schema::Message shop.Item>
# [name, number, type, label, json_name, presence?, map?, oneof, real_oneof]
["name", 1, :string, :optional, "name", false, false, nil, nil]
["price_cents", 2, :int64, :optional, "priceCents", true, false, "_price_cents", nil]
["stock", 3, :message, :repeated, "stock", false, true, nil, nil]
item.oneofs.map { |o| [o.name, o.synthetic?] }               # => [["_price_cents", true]]
item.nested_messages.map { |m| [m.name, m.map_entry?] }      # => [["StockEntry", true]]
Ractor.shareable?(file)                                      # => true
```

The objects speak Ruby (`:int64`, `:optional`, `:local`), carry derived answers
(`presence?`, `map?`, `real_oneof`, `packed?`) that the codec and emitters use, and hold
options as objects with readers (`options.deprecated?`, `options.extension(...)`).

### The translation to protoc's shape

`lib/protostar/schema/proto.rb` is the one place that knows protoc's shape:

- `File#to_proto` builds the `FileDescriptorProto` message of the bootstrap classes,
  as protoc's `FileDescriptor::CopyTo` writes it: `type_name`, `extendee`, `input_type`
  and `output_type` fully qualified with a leading dot, the declared label and type
  (`LABEL_OPTIONAL` and `TYPE_MESSAGE` for an editions `LEGACY_REQUIRED` or `DELIMITED`
  field), `json_name` on every field, no `syntax` for proto2, options messages with custom
  options as extension bytes. Every descriptor and `Options` has its own `to_proto`.
- `File#serialize` is `to_proto.encode`, except that `source_code_info`, thousands of
  locations on a large file, is written straight to bytes and put in its place among the
  fields. The bytes are protoc's: the 107 `.binpb` goldens are reproduced byte for byte.
- `File.from_proto(message_or_bytes, pool:)` reads a `FileDescriptorProto` into a draft,
  links it, and only then decodes the options messages, so a file's options can use the
  extensions the file itself declares, in one pass.
- `to_h` on any descriptor is `to_proto.to_h`: protoc's shape as a Hash, for reading. It
  shows no custom options, which are bytes in `to_proto`.

## 14. Editions and feature resolution

Editions replace the proto2/proto3 switches with *features*: per-element settings
(`field_presence`, `enum_type`, `repeated_field_encoding`, `utf8_validation`,
`message_encoding`, `json_format`, `enforce_naming_style`, `default_symbol_visibility`,
`enforce_proto_limits`) with defaults per edition, overridable at any level through
`option features.x = Y`.

The work is split three ways.

**Parsing and interpretation.** `features` is an ordinary field of every options message
(`FileOptions.features` is a `FeatureSet`), so `option features.field_presence = IMPLICIT;`
is interpreted like any other option. Custom features such as `(pb.cpp).string_type` are
extensions of `FeatureSet`, keyed by their extension descriptor inside the `features`
value.

**Resolution, in `Schema::Draft::Resolution`** (as protoc's `FeatureResolver` does), run by
the draft's `resolve`:

- Defaults come from `Schema::Features.defaults(edition)`, which picks, per feature, the
  last `[edition, value]` pair in `Features::DEFAULTS` at or before the file's edition.
  proto2 and proto3 files are resolved as `EDITION_PROTO2` and `EDITION_PROTO3`, so every
  descriptor has a complete feature set whatever its syntax.
- Features are merged down the tree: file, then message, then its oneofs, then fields (a
  field in a oneof inherits from the oneof), extension ranges, nested messages and enums,
  extensions; enum to values; service to methods. Identical `Features` objects are interned.
- For proto2 and proto3 files, `InferLegacyProtoFeatures` is applied per field: `required`
  means `LEGACY_REQUIRED`, `group` means `DELIMITED`, `[packed = ...]` sets
  `repeated_field_encoding`, proto3 `optional` means `EXPLICIT`.
- Then `PostProcessFieldFeatures`: a field with `LEGACY_REQUIRED` presence reports
  `label == :required`, and a message field with `DELIMITED` encoding reports
  `type == :group`, unless it is or sits in a map entry. `Field#declared_label` and
  `#declared_type` keep what was declared, and `to_proto` still writes `LABEL_OPTIONAL` and
  `TYPE_MESSAGE` (as protoc's `CopyTo` does).
- Each descriptor's options object is bound to its resolved features: `options.features`
  is `descriptor.features`, and the declared `FeatureSet` is `options[:features]`.

`Features::DEFAULTS` is a transcription of the `edition_defaults` annotations in
descriptor.proto, with line citations, not something computed from the file at compile
time. `test/schema/features_test.rb` pins it to the annotations in the golden
descriptor.proto.

An editions file, compiled:

```proto
edition = "2023";
package ed;
option features.field_presence = IMPLICIT;

message Node {
  int32 id = 1 [features.field_presence = LEGACY_REQUIRED];
  Node child = 2 [features.message_encoding = DELIMITED];
  repeated int32 ids = 3;
  string label = 4;
}
```

`to_proto` keeps protoc's spelling (`label: :LABEL_OPTIONAL`, `type: :TYPE_MESSAGE`, the
features as options, `syntax: "editions"`, `edition: :EDITION_2023`). The `Schema::Field`s
carry the resolved meaning:

```ruby
# [name, label, type, presence?, packed?, field_presence, message_encoding]
["id", :required, :int32, true, false, :LEGACY_REQUIRED, :LENGTH_PREFIXED]
["child", :optional, :group, true, false, :IMPLICIT, :DELIMITED]
["ids", :repeated, :int32, false, true, :IMPLICIT, :LENGTH_PREFIXED]
["label", :optional, :string, false, false, :IMPLICIT, :LENGTH_PREFIXED]
```

(`child` resolves to `IMPLICIT` presence from the file, yet `presence?` is true: message
fields always have presence.)

**Validation**, in three places, all with protoc's messages:

| Where | Checks |
|---|---|
| `Parser` | `optional`/`required` labels and `group` in editions; unknown editions |
| `Linker#setup_edition`, `#check_features` | edition range; features outside editions; features set to `*_UNKNOWN` values |
| `Validator#validate_file`, `#field_features`, `#feature_lifetimes`, `#feature_support_problem` | file-wide `LEGACY_REQUIRED`; presence on oneof, repeated, extension and message fields; implicit presence with defaults or closed enums; encodings on the wrong field types; `packed` and `ctype` in editions; `feature_support` lifetimes (`edition_introduced`, `edition_deprecated` as warnings, `edition_removed` with `removal_error`) for every option and enum value used |

Some of these, run as compiles:

```
e.proto:2:13: Label "required" is not supported in editions, use features.field_presence = LEGACY_REQUIRED.
e.proto:2:19: Implicit presence fields can't specify defaults.
e.proto:2:19: Features are only valid under editions.
e.proto:2:13: ctype option is not allowed under edition 2024 and beyond. Use the feature string_type = VIEW|CORD|STRING|... instead.
e.proto:1:11: Unknown edition "2077".
```

Custom features (`pb.cpp`, `pb.java`) are merged as explicit values only; their own
defaults are not resolved, since nothing in Ruby needs them (a WS1 decision).

## 15. The validator

`Compiler::Validator` holds the checks protoc runs after a file's options are interpreted.
They read the built `Schema::File` (for resolved features, types and options), reaching
each element's descriptor through `Linker#descriptor_of(node)`, and report against AST
positions. Options are read through their readers (`field.options.jstype`,
`range.options.declaration`, `enum.options.allow_alias?`), and the checks over option values
(`targets`, feature lifetimes) walk `MessageValue`s, custom options by their extension
descriptor. `validate` runs, in protoc's order and only while there are no
errors:

1. `validate_options`, per element in protoc's `VisitDescriptors` order
   (`Linker#each_element`):
   - file: editions-only file checks, non-lite file importing a lite file, proto3 rules
     (`validate_proto3`: no extension ranges, no MessageSet, extensions only of options,
     no required, no defaults, no closed enums, no groups), `import option` before 2024,
     `import weak` from 2024;
   - message: JSON name conflicts (default and custom, error or warning by
     `json_format`), extension range limits, extension declarations (numbers in range,
     unique, `full_name` and `type` together, `UNVERIFIED` with declarations);
   - field: feature support, field features, `ctype`, `lazy`, `packed` on non-packable
     types, MessageSet rules, lite extensions, maps (`validate_map`, `valid_map_entry?`),
     `jstype`, `json_name` on extensions, extension declarations matching the extension;
   - enum: name conflicts after prefix stripping (`enum_value_uniqueness`), first value
     zero for open enums, aliases without `allow_alias` (with "The next available enum
     value is N.");
   - service: methods' types must be messages;
2. `detect_map_conflicts`, only when there were errors (it explains them, as protoc does);
3. `unused_imports` (warnings);
4. with `protoc_cli` (the default): `naming_style` (`STYLE2024` and `STYLE2026`),
   `proto_limits` (65,535 fields, 255 oneofs, 255 fields per oneof, 65,535 enum values),
   `symbol_visibility` (STRICT);
5. `feature_lifetimes`.

`Validator.cli_checks(linkers, run)` runs once per `compile` over the named files, with no
positions, because protoc's command line does them after building: the generic services
deprecation warning, field numbers 19000 to 19999 (a CLI check in protoc 36.2, not a pool
error), option `targets` (an option declared for fields cannot be set on a message), and
the maximum edition.

The validation rules are pinned by 116 snippets in `test/compiler/validation_cases.rb`,
each recorded from protoc 36.2's own output (section 20).

## 16. Source info: spans, paths and comments

`SourceCodeInfo` is a list of locations, each a `path` into the `FileDescriptorProto` (field
numbers and indexes: `[4, 0, 2, 1]` is `message_type[0].field[1]`), a `span`, and comments.
protoc's output is tier B of the verification and is matched location for location.

### `SourceInfo::Recorder` and `Location`

`SourceInfo::Recorder` is protoc's `LocationRecorder` (as protoc does). The parser opens one
whenever it starts reading an element:

- `Recorder.new` (or `parent.child(*components)`) appends a `SourceInfo::Location` to the
  target list immediately, with the parent's path plus the components and a span starting
  at the current token. Appending at creation is what produces protoc's pre-order.
- `add_path` extends the path later, when the parser learns which field it is (a type
  becomes `FIELD_TYPE` 5 or `FIELD_TYPE_NAME` 6 only after it is parsed).
- `start_at`, `end_at` override the span; `finish` (the C++ destructor) ends it at the
  previous token unless already ended. The parser wraps recorders in `scoped` so `finish`
  runs on every exit path, as the destructor does.
- `record_legacy(node, kind)` stores the start position as one of the node's error
  positions (section 5).

```ruby
class Location
  attr_accessor :path, :span, :leading_comments, :trailing_comments, :leading_detached_comments
end
```

Once linking is done, `Location#to_schema` turns each into a frozen
`Schema::SourceInfo::Location` (comments read as UTF-8), which is what the built file
keeps.

Spans are 0-based `[start_line, start_col, end_line, end_col]`, with `end_line` omitted
when it equals `start_line` (`end_at` only appends the line when it differs).

The locations for the running example, as `file.to_proto.source_code_info.location`
gives them (each `to_h`):

```ruby
{span: [0, 0, 8, 1]}
{path: [12], span: [0, 0, 18]}
{path: [2], span: [1, 0, 13]}
{path: [4, 0], span: [4, 0, 8, 1], leading_comments: " A thing for sale.\n"}
{path: [4, 0, 1], span: [4, 8, 12]}
{path: [4, 0, 2, 0], span: [5, 2, 18], trailing_comments: " shown to buyers\n"}
{path: [4, 0, 2, 0, 5], span: [5, 2, 8]}
{path: [4, 0, 2, 0, 1], span: [5, 9, 13]}
{path: [4, 0, 2, 0, 3], span: [5, 16, 17]}
{path: [4, 0, 2, 1], span: [6, 2, 33]}
{path: [4, 0, 2, 1, 4], span: [6, 2, 10]}
{path: [4, 0, 2, 1, 5], span: [6, 11, 16]}
{path: [4, 0, 2, 1, 1], span: [6, 17, 28]}
{path: [4, 0, 2, 1, 3], span: [6, 31, 32]}
{path: [4, 0, 2, 2], span: [7, 2, 31]}
{path: [4, 0, 2, 2, 6], span: [7, 2, 20]}
{path: [4, 0, 2, 2, 1], span: [7, 21, 26]}
{path: [4, 0, 2, 2, 3], span: [7, 29, 30]}
```

Reading it: the file (empty path) spans everything; `12` is `syntax`, `2` is `package`;
`[4, 0]` is the message; within field 1 (`[4, 0, 2, 1]`), `4` is the label, `5` the type,
`1` the name, `3` the number. The map field records a `type_name` (6) location spanning
`map<string, int32>`. The synthesised `StockEntry` and `_price_cents` get no locations of
their own, as in protoc.

### Comment attachment

`Parser#try_consume_end_of_declaration(text, location)` is protoc's
`TryConsumeEndOfDeclaration` (as protoc does). Whenever a declaration ends (`;`, `{` or
`}`), it calls `next_with_comments`, and:

- the comments the lexer classified as the previous token's trailing comment go on the
  declaration that just ended;
- the leading comment and detached comments collected *before* this declaration started
  (held in `@upcoming_doc_comments` and `@upcoming_detached_comments`) go on it too;
- the new leading and detached comments are held for the next declaration.

For a `{`, the declaration that "ends" is the opening of a message, so a message's leading
comment is attached when its `{` is consumed, and the comment after `{` on the same line is
its trailing comment.

```proto
syntax = "proto3";

// detached: blank line follows

// leading for A
message A {
  int32 x = 1; // trailing for x
  // leading for y
  int32 y = 2;
  /* trailing for y,
     on the next line */

  int32 z = 3;
}
```

gives:

```ruby
{path: [4, 0], span: [5, 0, 13, 1], leading_comments: " leading for A\n", leading_detached_comments: [" detached: blank line follows\n"]}
{path: [4, 0, 2, 0], span: [6, 2, 14], trailing_comments: " trailing for x\n"}
{path: [4, 0, 2, 1], span: [8, 2, 14], leading_comments: " leading for y\n", trailing_comments: " trailing for y,\non the next line "}
```

The block comment on the line after `y` is `y`'s trailing comment because a blank line
separates it from `z`; the leading whitespace of its continuation line is stripped by the
lexer (as protoc does).

### Option locations are rewritten after interpretation

The parser records options under their `uninterpreted_option` path (`999`). Once options are
interpreted, `SourceInfo.rewrite_option_paths(locations, interpreted_paths)` is protoc's
`OptionInterpreter::UpdateSourceCodeInfo`: the location of each interpreted option takes the
path of the field it set, and the locations nested under it (name parts, value) are dropped.
For `Order` in section 10, before:

```ruby
{path: [4, 1, 7], span: [11, 2, 44]}
{path: [4, 1, 7, 999, 0], span: [11, 2, 44]}
{path: [4, 1, 7, 999, 0, 2], span: [11, 9, 17]}
{path: [4, 1, 7, 999, 0, 8], span: [11, 20, 43]}
{path: [4, 1, 7], span: [12, 2, 27]}
{path: [4, 1, 7, 999, 1], span: [12, 2, 27]}
{path: [4, 1, 7, 999, 1, 2], span: [12, 9, 21]}
{path: [4, 1, 7, 999, 1, 4], span: [12, 24, 26]}
{path: [4, 1, 7], span: [13, 2, 27]}
{path: [4, 1, 7, 999, 2], span: [13, 2, 27]}
{path: [4, 1, 7, 999, 2, 2], span: [13, 9, 19]}
{path: [4, 1, 7, 999, 2, 3], span: [13, 22, 26]}
```

and after:

```ruby
{path: [4, 1, 7], span: [11, 2, 44]}
{path: [4, 1, 7, 50001], span: [11, 2, 44]}
{path: [4, 1, 7], span: [12, 2, 27]}
{path: [4, 1, 7, 50001, 1], span: [12, 2, 27]}
{path: [4, 1, 7], span: [13, 2, 27]}
{path: [4, 1, 7, 3], span: [13, 2, 27]}
```

`50001` is the `limits` extension, `1` its `max` field, `3` is `MessageOptions.deprecated`.
The repeated `[4, 1, 7]` entries, one per statement, are protoc's too. So are some oddities
in the same file: the field's `[default = 1, json_name = "q"]` brackets get an options
location (`[4, 1, 2, 0, 8]`) even though nothing in them is an option, and `json_name`
gets two locations with the same path `[4, 1, 2, 0, 10]`, one for the whole assignment and
one for the value.

(The "before" list leaves out the locations of the option name parts, deeper than these.)

`Linker#locations` holds the rewritten list; with `source_info: true`, `build_schema` gives
it to the draft as the file's `SourceInfo`.

## 17. Diagnostics and error recovery

### From problem to diagnostic

Errors pass through three shapes:

| Shape | Where | Position |
|---|---|---|
| `[line, column, message]` | `Lexer`, `Parser#errors`, `#warnings` | 0-based |
| `Linker::Problem` (`severity`, `node`, `location`, `message`, `import`) | `Linker`, `OptionInterpreter`, `Validator` | AST node + position kind |
| `Compiler::Diagnostic(file, line, column, message, severity, path:)` | `Run#report` | 1-based, nil when protoc prints none |

`Run#load` resolves each problem's position with `problem.node.position(problem.location)`
(or `ast.import_positions[problem.import]`) and adds one to line and column.
`Diagnostic#to_s` prints protoc's format, `file:line:col: message`, with `warning: `
before warnings and no position when there is none. `Diagnostic#format(:gcc | :msvs)`
prints the disk path the way protoc's `--error_format` does, for the CLI.
`Compiler::Error#message` is the diagnostics joined by newlines, and `Error#diagnostics`
the list.

### Spans, codes and the rich renderer

`Run#report` also gives each linker problem its `spans`: the primary one runs from the
reported position to the end of the shortest source location that starts there (so
`foo.Bar` in a field type is underlined whole), and the problem's `related` nodes add
labelled secondary spans ("first used by `a`" for a duplicate field number, "first
defined here" for a name defined twice). Parser errors carry only a position; the
renderer underlines the token there. `Diagnostics::Codes` gives every message a code
(`P` parser, `L` linker, `V` validator), a short title, a label and a `help:` line,
matched by template; `test/diagnostics/codes_test.rb` reads the compiler's message
strings with Ripper, so a new message without a code fails. `Diagnostics::Renderer`
prints rustc's layout; `to_s` and `format` stay protoc's.

### Ordering and gating

The order of diagnostics is part of the contract, and comes from running the phases in
protoc's order and stopping where protoc stops:

- the lexer and parser report as they go; a file with parse errors stops there;
- imports are reported before importers (depth-first loading);
- inside the linker, `build_file` problems come before `cross_link` problems, and the
  suggestions come last;
- options are only interpreted, and the file only built, when linking found no errors;
- the validator only runs on an error-free build, except for the map conflict hints.

A link example, compared with protoc 36.2:

```proto
syntax = "proto3";
package p;
message A {
  Missing m = 1;
  int32 dup = 1;
  int32 big = 536870912;
}
enum E { FIRST = 1; }
```

```
link.proto:6:15: Field numbers cannot be greater than 536870911.
link.proto:4:3: "Missing" is not defined.
link.proto:6:15: Suggested field numbers for p.A: 2
```

The number error comes first although it is on a later line, because it is a `build_file`
check. `FIRST = 1` is not reported because the validator does not run on a file with link
errors (as protoc does). protoc prints one more line here; see section 22.

### Parse error recovery, compared with protoc

```proto
syntax = "proto3";
message A {
  int32 a = ;
  string b = 2
  int32 c = 3;
}
message B { int32 x = 1; }
enum
```

```
bad.proto:3:13: Expected field number.
bad.proto:5:3: Expected ";".
bad.proto:9:1: Expected enum name.
```

Identical to protoc 36.2's output. After `a`, the parser skips to `;` and carries on; `b`
is missing its `;` so the error is reported at `int32` on the next line, and recovery skips
that statement; `B` parses cleanly; `enum` at the end of input fails at end of file
(line 9).

### Other cases, all identical to protoc 36.2

```
x.proto:1:20: File recursively imports itself: x.proto -> y.proto -> x.proto
y.proto:1:20: Import "x.proto" was not found or had errors.
x.proto:1:20: Import "y.proto" was not found or had errors.
```

```
u.proto:1:20: warning: Import a.proto is unused.
```

```
o.proto:2:23: Enum type "google.protobuf.FileOptions.OptimizeMode" has no value named "FAST" for option "google.protobuf.FileOptions.optimize_for".
o.proto:4:20: Option "(nope)" unknown. Ensure that your proto definition file imports the proto which defines the option (i.e. via import option after edition 2024).
```

(The second file option in that file, `java_package = 5`, is never reported: interpretation
of the file's options stopped at `optimize_for`.)

```
p3.proto:3:22: Required fields are not allowed in proto3.
p3.proto:3:58: Explicit default values are not allowed in proto3.
p3.proto:2:18: The first enum value must be zero for open enums.
```

### `protoc_cli: false`

protoc's command line does more than a bare `DescriptorPool`: it loads imports from disk,
warns about unused imports, and enables naming style, proto limits, symbol visibility and
feature support checks. The `parser_unittest.cc` validation cases use a bare pool, where a
missing import is "Import \"x\" has not been loaded." `compile(..., protoc_cli: false)`
(`@api private`) switches to that behaviour so those cases can be replayed faithfully.

### Virtual names

Diagnostics use the name the file was imported by (`a.proto`), not the disk path protoc
prints (`src/a.proto`). `Diagnostic#path`, filled from `Compiler#disk_path`, carries the
disk spelling for the CLI.

## 18. Retention stripping and the two pools

Options can be declared `retention = RETENTION_SOURCE`: they exist while compiling (and are
used to validate later files) but are not written into descriptor sets or generated code.

`compile` therefore keeps two versions of each file:

- the **pool** (`compiler.pool`) gets the full file, as protoc's pool does, so files compiled
  later are validated against complete declarations (extension declarations, for example);
- `compile` **returns** `Compiler#output_file(f)`: a copy of the file without
  source-retention options, built into a private output pool and linked against the
  stripped copies of its imports. That is what protoc's `--descriptor_set_out` writes.
  `retain_options: true` returns the pool's files instead.

`Retention.strip(file, output_pool, options_type)` is `compiler/retention.cc` (as protoc
does): it walks each descriptor's options with the type of its options message, drops
every option field (known or extension) whose declaration has
`options.retention == :RETENTION_SOURCE`, drops options messages left empty by that, and
drops the source locations under anything removed, computing each descriptor's source path
on the way. `Schema::Draft.copy(file, pool:, source_info:) { |descriptor| options }` then
rebuilds the file into the output pool with the stripped options; custom options are
re-keyed to the output pool's copies of their extensions.

```proto
extend google.protobuf.MessageOptions {
  optional string src_only = 50010 [retention = RETENTION_SOURCE];
  optional string kept = 50011;
}
message M { option (src_only) = "x"; option (kept) = "y"; }
```

```ruby
compiler.compile(["r.proto"], ...).last.find_message("r.M").options
# => #<Protostar::Schema::MessageOptions (r.kept): "y">
compiler.compile(["r.proto"], ..., retain_options: true).last.find_message("r.M").options
# => #<Protostar::Schema::MessageOptions (r.src_only): "x", (r.kept): "y">
```

With `retain_options: true` the returned file is the pool's own object
(`c2.pool.file("r.proto").equal?(full)` is true); without it, it is a copy.

## 19. After the compiler: emitters

The emitters under `lib/protostar/compiler/emitters/` consume `Schema::File`s (usually from
`compile(..., source_info: true)` so comments survive):

| Emitter | Output |
|---|---|
| `Emitters::Ruby` | protostar's own `_pb.rb`: a `Protostar::DSL.file` block plus constants named as protoc's Ruby generator names them |
| `Emitters::GoogleRuby` | protoc's `ruby_generator.cc` output, byte for byte |
| `Emitters::Rbs` | protoc's `rbs_generator.cc` output |
| `Emitters::Grpc` | grpc's `_services_pb.rb` |
| `Emitters::DescriptorSet` | `--descriptor_set_out` bytes |

The native emitter reads the Schema objects and turns them back into DSL calls, re-folding
map entries, synthetic oneofs and groups into sugar (`m.map`, `proto3_optional: true`,
`m.group`) wherever the sugar rebuilds the identical descriptor, and falling back to
explicit calls where it would not. "Identical" is asked of the descriptors, with the
draft's naming rules: an entry is `map` sugar when it is named `map_entry_name(field)`,
has exactly `key = 1` and `value = 2` with derived json names and no options beyond the
field's `features`, and `map_entry: true` as its only option. Options are written as
keywords (`deprecated: true`), custom ones under `extensions:` by full name; a custom
option whose extension the file reaches only through `import option` is written as
unknown bytes, as protoc's own Ruby generator embeds it, since the generated file does not
load its option-only imports. Leading comments from source info
become `#` comments. For the running example:

```ruby
# frozen_string_literal: true

# Generated by protostar from shop.proto. Do not edit.

require "protostar"

Protostar::DSL.file("shop.proto", package: "shop", syntax: :proto3) do |f|
  # A thing for sale.
  f.message "Item" do |m|
    m.field :name, 1, :string
    m.field :price_cents, 2, :int64, proto3_optional: true
    m.map :stock, 3, :string, :int32
  end
end

module Shop
  Item = Protostar::DSL.message("shop.Item")
end
```

At load time, `Protostar::DSL.file` drives the draft API: its builders are adapters
(`m.map :stock, 3, :string, :int32` is `draft.map("stock", 3, key: :string, value: :int32)`),
so the map entry and the `_price_cents` oneof are synthesised again by the draft, with the
parser's rules, and the file is resolved and frozen into the generated pool. The compiler
is therefore not needed at runtime: generated files carry the descriptor as Ruby, and
`test/emitters/ruby_corpus_test.rb` checks for every corpus file that loading the generated
Ruby serializes to exactly the compiler's bytes, custom options included.

The other emitters read Schema objects too. The Google-format emitter embeds
`file.serialize(source_info: false, default_json_names: false)`, protoc's bytes without the
json names a `.proto` did not spell out; the descriptor set emitter writes `serialize`; RBS
and gRPC read descriptors and option readers (`file.options.ruby_package`,
`descriptor.options.deprecated?`).

## 20. How it is verified against protoc

protoc is not needed to run the tests. Everything protoc produced was recorded once and
committed under `test/corpus/`.

| Check | Test | What is compared | Needs |
|---|---|---|---|
| Tier A, descriptors | `test/compiler/corpus_test.rb` | for each of the 107 `.proto` files in `test/corpus/protobuf` (17,999 lines), compiled with the corpus include roots, every file of the result (the file and its transitive imports, 237 files in all), translated by `to_proto`, against the `.json` golden protoc 36.2 wrote with `--include_imports`, read by protostar's own JSON parser into the same descriptor.proto classes; same file order; `Ractor.shareable?`; diagnostics equal to protoc's (only the 6 generic-services warnings) | nothing |
| Custom options | `test/compiler/custom_options_test.rb` | every options message of every corpus file: the bytes `to_proto` writes for it and the `.binpb` golden's, both decoded by the `google-protobuf` gem with a pool built from the golden and compared as JSON; plus targeted assertions on `unittest_custom_options.proto` that run without the gem | oracle gem for the sweep |
| Tier B, source info | `test/compiler/source_info_test.rb` | `source_code_info` of every corpus file, location for location (path, span, comments), against the `.binpb` golden decoded by the gem | oracle gem |
| Bytes | `test/emitters/descriptor_set_test.rb` | `DescriptorSet` output with `--include_imports --include_source_info` against the `.binpb` golden, byte for byte, for all 107 | nothing |
| Parser | `test/compiler/parser_cases_test.rb` | the 239 inline cases of protoc's `parser_unittest.cc` (90 parse-to, 83 parse errors, 16 early-exit errors, 48 validation errors, 2 warnings) plus 28 `SourceInfoTest` cases, extracted by `script/extract_parser_cases.rb` into `test/corpus/parser_cases/cases.json` | nothing |
| Validation | `test/compiler/validation_test.rb` | 116 snippets, one or more per rule, each with protoc 36.2's recorded output (`script/record_validation_cases.rb`); one pinned deviation | nothing |
| Resolver | `test/compiler/resolver_test.rb` | the compiler and `Schema::Resolver` agree on WS1's lookup cases | nothing |
| Round trip | `test/schema/golden_round_trip_test.rb`, `test/bootstrap/descriptor_set_test.rb` | every `.binpb` file through `File.from_proto` and back through `serialize`, byte for byte, and through `to_proto` against the golden JSON | nothing |
| Units | `lexer_test.rb`, `parser_test.rb`, `facade_test.rb` | tokens, positions, literals and lexer errors; parser details; include path order, bundled includes, pool reuse, diagnostics format | nothing |

Two things about the goldens. The `.json` files cannot hold custom options, because protoc's
JSON printer drops extensions it cannot name. Neither does `to_proto.to_h`: in `to_proto`
custom options are extension bytes, which the bootstrap classes keep as unknown fields and
`to_h` leaves out, so the comparison needs no stripping, and the custom options test and
the byte-for-byte tests cover what it cannot see. And the `.json` files were printed by
google-protobuf 4.31, which wrote editions it had no name for (`EDITION_2026`) as numbers;
protostar's JSON parser names them from today's descriptor.proto. (`GoldenHash` used to
convert the JSON by hand, reading descriptor.proto's metadata from its own golden; it is now
three lines over `FileDescriptorSet.decode_json`.)

The byte-for-byte descriptor set test is worth noting: since the `.binpb` goldens contain
both custom options and source info, it checks tier B and custom options in the default
suite, without the oracle gem, just less legibly when it fails.

Today's run of the compiler tests: 759 runs, 3,040 assertions, 214 skips without the oracle,
in 6.8 s; with `BUNDLE_WITH=oracle PROTOSTAR_ORACLE=1`, 759 runs, 127,486 assertions, 0
skips, in 17.7 s (21 s before the compiler drafted directly).

The claim "this is a port of protoc" is verified by behaviour, not by reading side by side:
the vendored corpus contains `parser_unittest.cc` but not `parser.cc`, `tokenizer.cc` or
`descriptor.cc`. Where this document cites a protoc function name, it is the one the Ruby
code names in its comments.

## 21. Performance

Measured on Ruby 3.4.1, arm64 macOS (Apple Silicon), interpreter only (this Ruby has no
YJIT), best of 10 runs (3 for the corpus), with `bench/compiler_bench.rb` (the DSL and `add_serialized_file` rows are in `bench/definition_bench.rb`). `unittest.proto`
is 65,682 bytes, 2,731 lines. "Before" is the same bench on the commit before WS14 (the
descriptor hash and `Schema::Builder`), run on the same machine the same day; the
"doc" column is what this section said then, measured with other scripts.

| What | Doc | Before | Now |
|---|---|---|---|
| Lexing `unittest.proto` (all tokens, no parsing) | 15.2 ms | 15.6 ms | 15.3 ms |
| Parsing it (lexing, AST, source locations) | 25.4 ms | 27.7 ms | 26.2 ms |
| Linking it, imports already in the pool (`Linker#link`: drafting, option interpretation, resolve and freeze) | 37.1 ms | 42.4 ms | 31.3 ms |
| Validating it (`Validator#validate`) | 7.3 ms | 9.0 ms | 8.7 ms |
| Building it from its serialized `FileDescriptorProto` (before: hash decode and `Schema::Builder`; now: `File.from_proto`) | | 23.5 ms | 19.5 ms |
| `compile` of `unittest.proto` alone, imports pooled, built-in descriptor.proto ready (parse, link, validate, stripped copy) | 92 ms | 104.9 ms | 85.3 ms |
| `compile` of `unittest.proto` on a fresh `Compiler` (its imports and the built-in descriptor.proto compiled too) | 129 ms | 136.6 ms | 114.0 ms |
| the same, `retain_options: true` (no stripped copies) | 103 ms | 118.2 ms | 96.2 ms |
| the same, `source_info: true` | 202 ms | 211.4 ms | 144.8 ms |
| `descriptor.proto` on a fresh `Compiler` | 28 ms | 30.4 ms | 26.6 ms |
| Native Ruby emitted for `unittest.proto` and its 3 imports | | 12.4 ms | 11.0 ms |
| That Ruby loaded through the DSL into a fresh pool | | 18.9 ms | 20.5 ms |
| `add_serialized_file` of `unittest.proto` and its 3 imports | | 33.2 ms | 20.7 ms |
| `to_proto` of `unittest.proto` with source info | | 49.8 ms | 32.1 ms |
| `serialize` of it with source info | | 34.9 ms | 21.8 ms |
| `serialize` of it without source info | | 9.9 ms | 9.6 ms |
| The whole corpus: 107 files, a fresh `Compiler` each, 237 file compiles | 5.0 s | 5.10 s | 3.95 s |
| The whole corpus with `source_info: true` | 6.4 s | 6.48 s | 4.65 s |

For comparison, protoc 36.2 compiles `unittest.proto` to a descriptor set in about 20 ms
wall time, process start included.

Where the time goes:

- The lexer is a byte-at-a-time loop with table lookups, about 60% of parse time. It
  allocates a `Token` per token plus a `dup` for `previous`.
- Each file is drafted once. Option interpretation reads the draft (resolved once without
  options, about 2 ms on `unittest.proto`) where it used to build the whole file from a
  hash first; names resolved by `cross_link` are not resolved again. That and the hashes
  no longer built and checked key by key are the 11 ms gained in linking.
- `compile` still returns a source-retention-stripped copy, now made by `Draft.copy` from
  the Schema objects rather than by stripping a hash and building it again.
- A fresh `Compiler` compiles the bundled descriptor.proto once (about 27 ms) the first
  time a file needs an options message it does not import. The result is memoised on the
  `Compiler` instance, not per process.
- `source_info: true` costs about 30 ms on `unittest.proto` (70 ms before): the 5,850
  locations become frozen `Schema::SourceInfo::Location`s once, instead of being turned
  into hashes, built, filtered as hashes and built again in the copy.
- Loading generated Ruby is 8% slower than before (18.9 to 20.5 ms for four files): every
  descriptor now has an options object bound to its features (interned when empty), and
  the DSL's adapters add a call per element. It is the one row that lost ground.
- `serialize` builds the `FileDescriptorProto` message tree and encodes it, except for
  `source_code_info`, which it writes straight to bytes: encoding 5,850 small `Location`
  messages through the generic encoder took longer than the whole file did before.
- Building is cheap relative to what it once was: `Ractor.make_shareable` alone used to take
  1.4 s for this file before the deep-freeze-first change.

These numbers are fine for a code generator run at build time. Nothing in the runtime path
(loading generated `_pb.rb` files) goes through the compiler.

## 22. Known differences and sharp edges

From the WS2 report, still true:

- **Cross-file extension number clash.** Fixed in WS13: `Schema::Pool#add` warns and keeps
  the first, as protoc does, and the linker reports protoc's warning.
- **Several unused imports** are reported in import order; protoc iterates a hash set, so
  its order is unspecified.
- **Missing `import option` files**: protoc 36.2 aborts with a CHECK failure when writing
  the descriptor set; we report "File not found." and continue.
- **Not implemented**: the `debug_redact` check of `ValidateOptionImports`, alias and custom
  JSON-string checks of `CheckEnumCustomStringUniqueness` beyond plain names, text-format
  corners in aggregates (`#` comments, `allow_f_after_float`, field numbers), placeholder
  and lazy-dependency pool modes, `--direct_dependencies`.
- **Float custom-option values** are stored as their float32 value, not the literal.

Found while writing this document:

- **A duplicate field number goes unreported after an unresolved type.** In the link example
  of section 17, protoc 36.2 also prints
  `link.proto:5:15: Field number 1 has already been used in "p.A" by field "m". Next available field number is 2.`
  We do not. `Linker#cross_link_field` returns as soon as the type lookup fails, before it
  records `[holder, number]` in `@fields_by_number`, so the later `dup = 1` finds no
  conflict. protoc still registers the field's number. The file is rejected either way;
  only the extra line is missing.

Things to know when changing the code:

- The pool is shared across `compile` calls and never forgets; recompiling a changed file
  needs a new pool.
- `compile` returns copies, not pool members, unless `retain_options: true`.
- The compiler's parser expands maps, groups and proto3 `optional` itself, because
  protoc's parser output is a tested contract (section 5); the naming rules it uses are the
  draft API's. A change to them is a change in `Schema::Draft`, and the parser follows.
- Custom options are keyed by extension descriptor. Code that copies a file into another
  pool must re-key them (`Draft.copy` does, through `Options.build`), or the copy's options
  point into the old pool.
- Diagnostics use virtual names; `Diagnostic#path` has the disk path.
- Feature defaults are transcribed in `Schema::Features::DEFAULTS`. A new edition means
  editing that table (and `Linker::MAXIMUM_EDITION`), not only updating the bundled
  descriptor.proto.
- Ordering is behaviour. Moving a check from one linker phase to another, or making a phase
  run despite earlier errors, changes which diagnostics protoc-identical tests see.

## 23. File map

| File | Lines | Contents |
|---|---|---|
| `lib/protostar/compiler.rb` | 261 | `Compiler` facade, `Diagnostic`, `Error`, include path resolution, built-in descriptor.proto, `output_file`, `simple_dtoa`, `simple_ftoa`, `c_escape` |
| `lib/protostar/compiler/lexer.rb` | 659 | `Lexer`, `Lexer::Token`, `Lexer::CommentCollector`, literal parsing |
| `lib/protostar/compiler/parser.rb` | 1,696 | `Parser`, source path constants, map entry and synthetic oneof expansion, recovery |
| `lib/protostar/compiler/ast.rb` | 193 | `AST::*` nodes |
| `lib/protostar/compiler/source_info.rb` | 146 | `SourceInfo::Location`, `Recorder`, `rewrite_option_paths` |
| `lib/protostar/compiler/run.rb` | 155 | `Run`: loading, cycles, reporting |
| `lib/protostar/compiler/symbol_table.rb` | 223 | `SymbolTable`, `SymbolTable::Symbol` |
| `lib/protostar/compiler/linker.rb` | 883 | `Linker`, `Problem`, `Pending`, drafting the file |
| `lib/protostar/compiler/option_interpreter.rb` | 363 | `OptionInterpreter` |
| `lib/protostar/compiler/text_format.rb` | 340 | `TextFormat` (aggregates) |
| `lib/protostar/compiler/validator.rb` | 943 | `Validator` and the CLI checks |
| `lib/protostar/compiler/retention.rb` | 104 | `Retention.strip` |
| `lib/protostar/compiler/include/` | | bundled `google/protobuf/*.proto` (14 files) and LICENSE |
| `lib/protostar/schema/draft.rb` | 779 | the draft classes `Schema::File.draft` makes, the naming rules |
| `lib/protostar/schema/draft/resolution.rb` | 171 | `Draft::Resolution`: options objects, feature resolution, defaults |
| `lib/protostar/schema/draft/copy.rb` | 88 | `Draft.copy`: a built file rebuilt for another pool |
| `lib/protostar/schema/options.rb` | 367 | `MessageValue`, `Options` and its nine subclasses |
| `lib/protostar/schema/proto.rb` | 576 | the translation to and from protoc's shape behind `to_proto`, `serialize` and `from_proto` (one-line delegations on the descriptor classes, autoloading it), the option value codec |
| `lib/protostar/schema/resolver.rb` | 118 | `Schema::Resolver`: the same scoping rule over built files |
| `lib/protostar/schema/features.rb` | 152 | `Schema::Features`, `EDITIONS`, `DEFAULTS` |
| `lib/protostar/dsl.rb` | 351 | `Protostar::DSL`, adapters onto the draft API |
| `lib/protostar/compiler/emitters.rb`, `emitters/*.rb` | | naming, printing, the five emitters |
| `script/extract_parser_cases.rb`, `script/record_validation_cases.rb` | | regenerate the recorded protoc expectations |
| `test/support/ast_hash.rb`, `test/support/golden_hash.rb` | | the parser's pre-link `FileDescriptorProto` for the parser tests; golden JSON read into the bootstrap classes |
