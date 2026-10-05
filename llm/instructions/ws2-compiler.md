# WS2: the compiler front-end (`Protostar::Compiler`)

Turn `.proto` source into `Protostar::Schema::File` objects whose `to_h` equals, key for
key, what protoc 36.2 puts in a `FileDescriptorProto`. Every file protoc accepts we accept
with the same descriptor; every file protoc rejects we reject with the same
`file:line:col: message`. Read `ws1-descriptor-model.md` first: the descriptor hash it
defines is your output, and `Schema::Builder`, `Schema::Resolver` and
`Schema::Pool` are yours to use. Read `llm/outputs/ws1-report.md` for what WS1 actually
shipped and any deviations.

## Deliverables

`lib/protostar/compiler.rb` and `lib/protostar/compiler/` holding the lexer, parser, AST,
linker, validator, source-info builder, diagnostics and the facade. The bundled standard
imports under `lib/protostar/compiler/include/google/protobuf/` (copy `descriptor.proto`,
`any`, `api`, `duration`, `empty`, `field_mask`, `source_context`, `struct`, `timestamp`,
`type`, `wrappers`, `cpp_features`, `java_features` and `compiler/plugin.proto` from the
corpus, with the LICENSE). Tests under `test/compiler/`. Committed fixtures extracted from
`parser_unittest.cc` under `test/corpus/parser_cases/` with the script that made them in
`script/`. No CLI yet; that is WS4.

## Facade

```ruby
compiler = Protostar::Compiler.new(include_paths: ["proto"], pool: Protostar::Schema::Pool.new)
files = compiler.compile(["foo/bar.proto"], source_info: true)   # => Array<Schema::File>, imports first
hashes = compiler.compile_to_hashes(["foo/bar.proto"])            # => the descriptor hashes
```

`compile` resolves each named file against the include paths in order, then the bundled
includes last, exactly as protoc does. Imports are compiled transitively, in dependency
order, each file once, and every built file is added to the pool. Files already in the
pool are reused, not recompiled. Errors raise `Protostar::Compiler::Error` carrying
`diagnostics`, an Array of `Diagnostic(file, line, column, message)` with protoc's
1-based line and column, and `Error#message` lists them one per line as
`file:line:col: message`. Collect several errors per file where protoc does (it reports
every validation error of a file, and parse errors per statement after recovery); match
protoc's wording.

## Stages

**Lexer.** protoc's tokenizer (`io/tokenizer.cc` semantics): identifiers, integer
literals (decimal, `0x` hex, leading-zero octal), floats (`1.5`, `1e10`, `.5`, `1.`, with
an optional exponent sign), strings in single or double quotes with every escape protoc
knows (`\a \b \f \n \r \t \v \\ \' \" \? \ooo \xhh \uhhhh \Uhhhhhhhh`), adjacent string
literals concatenated, `//` and `/* */` comments kept with their positions for source
info, symbols. Tokens carry 0-based line and column for spans and 1-based for
diagnostics. Integer literals overflowing uint64 are errors with protoc's text.

**Parser.** A faithful AST with positions on every node. The full grammar: `syntax`,
`edition`, `package`, `import` with `public` and `weak`, `option` at every level
including aggregate values in braces (text-format syntax, kept as a raw token stream for
the linker to interpret against the option's message type) and parenthesised extension
names with dotted suffixes (`(my.opt).sub.field`), `message`, fields with `optional`,
`required`, `repeated` and no label, `oneof`, `map<K, V>`, `group`, `enum` with values,
`reserved` numbers, ranges (`to`, `max`) and names (quoted in proto2 and proto3,
identifiers in editions), `extensions` ranges with options and `declaration`s, `extend`,
`service` and `rpc` with `stream`, options in bodies and the `returns` clause, empty
statements, and nesting wherever protoc allows it. Error recovery: on a parse error skip
to the end of the statement or block like protoc and continue.

**Source info.** `SourceCodeInfo` locations with paths and spans identical to protoc's,
and comments attached by protoc's rules (leading, trailing, detached; see
`parser.cc` around `ConsumeEndOfDeclaration` and the long comment in `descriptor.proto`
on `SourceCodeInfo`). Spans are `[start_line, start_col, end_line, end_col]`, 0-based,
with the end line omitted when it equals the start line. This is tier B; it is verified
against the `.binpb` goldens through the oracle gem (see Testing), so get it right.

**Linker.** Builds a symbol table of the file being compiled (from the AST) merged with
the pool's descriptors for its imports, with dependencies visible only through direct
imports and transitively through `public` imports, and resolves every name with protoc's
scoping rule (the first-component rule; use `Schema::Resolver` if WS1 made its algorithm
usable over an abstract lookup, otherwise implement the same rule and test that both agree
on the Resolver's cases). Produces the descriptor hash with fully qualified, leading-dot
`type_name` and `extendee`; synthesises map entry messages (`XxxEntry` with `map_entry`
option, `key` 1 and `value` 2, placed in `nested_type` where protoc places them),
proto3 `optional` synthetic oneofs (`_name`, appended after the real oneofs),
group field names (lower-cased type name) and their nested message, `json_name` for
every field by protoc's rule, `default_value` strings as protoc stores them (bytes
defaults C-escaped, floats and ints as written). Interprets options: known options by
walking the option message's fields in the symbol table (`google.protobuf.FileOptions`
and friends are ordinary messages from the bundled `descriptor.proto`, which must be
compilable by this same pipeline, so option interpretation must work from the symbol
table of the file being compiled, not from already-built descriptors), typed by the
field's type, aggregate values parsed as text format against the message type; custom
options resolved to extensions and stored under `:__extensions` by full name;
`uninterpreted_option` never appears in the output. Then `Schema::Builder.build` makes
the `File`, and Builder errors are mapped back to the AST position of the offending
reference.

**Validator.** protoc's checks with protoc's messages: duplicate symbols (including enum
values in the enclosing scope), duplicate field numbers, numbers outside 1 to 536870911
and inside 19000 to 19999, reserved number and name use, `required` and
`optional` rules per syntax, proto3 first enum value zero, proto3 enum and message
names, map key types and that map fields are not repeated or in oneofs, oneof field
labels, extension range overlaps and extension numbers inside declared ranges, `json_name`
conflicts, `packed` on non-packable types, groups only in proto2, syntax and edition
rules (`edition` values protoc 36.2 supports; `required` and `group` forbidden in
editions; feature validity per edition), import cycles, missing imports, unused imports
as warnings (protoc warns, not errors), default values valid for the type and absent on
repeated, message and proto3 fields, `allow_alias` rules, service method types being
messages, option types matching values, options set twice.

## Testing

- **Tier A, the whole corpus.** For every `.proto` under `test/corpus/protobuf`, compile
  it with the corpus include roots from `test/support/corpus.rb` and compare the
  descriptor hash of every file in the result (the file and its transitive imports)
  with the matching golden `.json` converted by `test/support/golden_hash.rb`, with
  `source_code_info` removed. Equality must be exact. Expect to need the bundled
  `descriptor.proto` for options, and expect `unittest_custom_options.proto` and
  `unittest_features.proto` to be the hard ones.
- **Tier B, source info.** The same comparison with `source_code_info` included, taking
  the expected value from the `.binpb` golden decoded by the `google-protobuf` oracle gem
  (`Google::Protobuf::FileDescriptorSet.decode(bytes).to_h`). These tests `skip` without
  `PROTOSTAR_ORACLE=1` and must pass in the oracle CI job.
- **parser_unittest.cc.** Write `script/extract_parser_cases.rb` that pulls the inline
  cases out of `test/corpus/protobuf/src/google/protobuf/compiler/parser_unittest.cc`:
  success cases (proto text plus expected text-format `FileDescriptorProto`) and error
  cases (proto text plus expected `line:col: message` lines). For success cases the script
  converts the expected text format to JSON with `protoc --encode` and the oracle gem at
  extraction time and commits the result under `test/corpus/parser_cases/`; tests then
  need neither. Map the expectations faithfully: some cases there test the parser in
  isolation with validation off; replicate that with a `validate: false` switch rather
  than skipping them.
- **Validation errors.** Hand-written `.proto` snippets per rule above, each asserting
  protoc's exact message. protoc 36.2 is at `~/.cache/protostar/protoc-36.2/bin/protoc`;
  run it when you are unsure of the wording and record what it said in the test.
- **Diagnostics format**, include-path resolution order, bundled includes, compiling a
  file twice through the pool, and the facade API.

## Out of scope

Emitting Ruby, the CLI, `FileDescriptorSet` bytes, decoding `.binpb` (the oracle gem does
that in tests), any text-format parser beyond what option aggregates need. Keep the
aggregate-value parser small and private; WS5 will write the real one.
