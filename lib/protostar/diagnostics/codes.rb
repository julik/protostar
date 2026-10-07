# frozen_string_literal: true

module Protostar
  module Diagnostics
    # Every message the compiler can report, with a stable code: `P` for the
    # lexer and parser, `L` for the linker and option interpreter, `V` for the
    # validator (the checks protoc runs once a file is built). Lint rules have
    # `W` codes of their own, in {Lint::RULES}.
    #
    # A message is matched against templates, protoc's wording with `%{name}`
    # where it varies; the captures fill the entry's short title, the label
    # under the span and the `help:` line. `protostar lint --explain CODE`
    # prints {Entry#explanation}.
    module Codes
      # One code
      class Entry
        # @return [String] e.g. "L0301"
        attr_reader :code
        # @return [String] a few words, as `--explain` heads it
        attr_reader :summary
        # @return [Array<String>] protoc's messages, `%{name}` where they vary
        attr_reader :templates
        # @return [String] what the error means, an example and the fix
        attr_reader :explanation

        def initialize(code, summary, templates, explanation, title: nil, label: nil, help: nil, note: nil)
          @code = code
          @summary = summary
          @templates = templates.freeze
          @explanation = explanation
          @title = title
          @label = label
          @help = help
          @note = note
          @patterns = templates.map { |t| [Codes.pattern(t), t.gsub(/%\{\w+\}/, "").size] }.freeze
          freeze
        end

        # @return [Array(MatchData, Integer), nil] the best match and its literal length
        def match(message)
          best = nil
          @patterns.each do |pattern, weight|
            m = pattern.match(message)
            best = [m, weight] if m && (best.nil? || weight > best[1])
          end
          best
        end

        # @return [String, nil] the short title for a match
        def title(captures)
          fill(@title, captures)
        end

        # @return [String, nil] the label under the primary span
        def label(captures)
          fill(@label, captures)
        end

        # @return [String, nil]
        def help(captures)
          fill(@help, captures)
        end

        # @return [String, nil]
        def note(captures)
          fill(@note, captures)
        end

        private

        # A template with a capture the match lacks is left out; protoc's quotes
        # in what is filled in become backticks
        def fill(template, captures)
          return nil unless template
          template.gsub(/%\{(\w+)\}/) do
            captures.fetch($1.to_sym) { return nil }.gsub(/"([^"]*)"/, '`\1`')
          end
        end
      end

      # A {Codes.lookup} result
      class Match
        # @return [Entry]
        attr_reader :entry
        # @return [Hash{Symbol => String}]
        attr_reader :captures

        def initialize(entry, captures)
          @entry = entry
          @captures = captures.freeze
          freeze
        end

        # @return [String]
        def code
          @entry.code
        end
      end

      # @return [Regexp] the template with each `%{name}` as a lazy named group
      def self.pattern(template)
        source = template.split(/(%\{\w+\})/).map do |part|
          part.start_with?("%{") ? "(?<#{part[2..-2]}>.*?)" : Regexp.escape(part)
        end.join
        Regexp.new("\\A#{source}\\z", Regexp::MULTILINE)
      end

      # @param message [String] as the compiler reports it
      # @return [Match, nil] the entry whose template matches the most literal text
      def self.lookup(message)
        best = nil
        ENTRIES.each do |entry|
          m, weight = entry.match(message)
          best = [entry, m, weight] if m && (best.nil? || weight > best[2])
        end
        return nil unless best
        captures = best[1].names.to_h { |n| [n.to_sym, best[1][n]] }
        Match.new(best[0], captures)
      end

      # @param code [String]
      # @return [Entry, nil]
      def self.[](code)
        BY_CODE[code.upcase]
      end

      # @param diagnostic [Compiler::Diagnostic]
      # @return [Compiler::Diagnostic] with the code, title, label, help and note the
      #   catalogue has for its message
      def self.annotate(diagnostic)
        match = lookup(diagnostic.message)
        return diagnostic unless match
        entry = match.entry
        c = match.captures
        spans = diagnostic.spans
        spans = [Span.new(diagnostic.line, diagnostic.column)] if spans.empty? && diagnostic.line
        label = entry.label(c)
        if label && (first = spans.first) && first.label.nil?
          spans = [first.with_label(label), *spans.drop(1)]
        end
        diagnostic.with(code: entry.code, title: entry.title(c), spans: spans,
          help: diagnostic.help + [entry.help(c)].compact, notes: diagnostic.notes + [entry.note(c)].compact)
      end

      ENTRIES = []

      def self.define(code, summary, templates, explanation, **kwargs)
        ENTRIES << Entry.new(code, summary, Array(templates), explanation, **kwargs)
      end
      private_class_method :define

      # Lexer

      define "P0101", "control character in the source", "Invalid control characters encountered in text.", <<~TEXT
        The file holds a byte below 32 that is not whitespace, outside of a string or comment. It usually comes
        from a bad copy and paste or an editor that saved a stray escape.

            message A {}\\x01

        Delete the character; `cat -v file.proto` shows where it is.
      TEXT

      define "P0102", "tokens run together",
        ["Need space between identifier and decimal point.", "Need space between number and identifier."], <<~TEXT,
          A number and a word touch, so the tokenizer cannot tell where one ends.

              int32 a = 1foo;
              option x = foo.5;

          Put a space between them, or remove the stray characters.
        TEXT
        title: "missing space between tokens", label: "here"

      define "P0103", "not UTF-8", "Proto file starts with 0xEF but not UTF-8 BOM. Only UTF-8 is accepted for proto file.",
        <<~TEXT
          The file starts with the first byte of a UTF-8 byte order mark but not the rest of it. `.proto` files are
          UTF-8; this one was probably saved in another encoding.

          Save the file as UTF-8, with or without the byte order mark.
        TEXT

      define "P0104", "unterminated string",
        ["Unexpected end of string.", "Multiline strings are not allowed. Did you miss a \"?."], <<~TEXT,
          A string literal is not closed before the end of its line. Strings cannot span lines; adjacent literals
          are joined, so a long one can be split.

              option java_package = "com.example;

          Close the quote. For a long string, write `"first part" "second part"`.
        TEXT
        title: "unterminated string literal", label: "string starts here", help: "close the string on the same line"

      define "P0105", "bad escape sequence",
        ["Expected hex digits for escape sequence.", "Expected four hex digits for \\u escape sequence.",
          "Expected eight hex digits up to 10ffff for \\U escape sequence", "Invalid escape sequence in string literal."],
        <<~TEXT, label: "here"
          A backslash in a string starts an escape that is not one of protobuf's: `\\a \\b \\f \\n \\r \\t \\v \\\\ \\? \\' \\"`,
          octal `\\123`, hex `\\x7f`, `\\u` with four hex digits or `\\U` with eight.

              string s = 1 [default = "C:\\path"];

          Escape the backslash itself (`\\\\`) or use one of the escapes above.
        TEXT

      define "P0106", "malformed number",
        ["\"0x\" must be followed by hex digits.", "Numbers starting with leading zero must be in octal.",
          "\"e\" must be followed by exponent.", "Already saw decimal point or exponent; can't have another one.",
          "Hex and octal numbers must be integers."], <<~TEXT, label: "here"
            A numeric literal does not follow protobuf's grammar: hex is `0x` and hex digits, a leading zero means
            octal, and an exponent needs digits after the `e`.

                int32 a = 09;

            Write the number in decimal, or fix the hex, octal or exponent part.
          TEXT

      define "P0107", "non-ASCII code point", "Interpreting non ascii codepoint %{codepoint}.", <<~TEXT, label: "here"
        A `\\u` or `\\U` escape names a code point above 127 in a context that is read as bytes; protoc warns and
        stores its UTF-8 encoding.

        If that is what you meant, write the character itself in the UTF-8 source.
      TEXT

      define "P0108", "nested block comment", "\"/*\" inside block comment.  Block comments cannot be nested.",
        <<~TEXT, title: "block comments cannot be nested", label: "nested `/*`"
          A `/*` appears inside a `/* ... */` comment. Block comments end at the first `*/`, so nesting does not work.

              /* outer /* inner */ */

          Use `//` line comments to comment out code that has block comments in it.
        TEXT

      define "P0109", "unterminated block comment", ["End-of-file inside block comment.", "  Comment started here."],
        <<~TEXT, title: "unterminated block comment"
          A `/*` comment is never closed, so the rest of the file is part of it.

              /* TODO
              message A {}

          Close it with `*/`.
        TEXT

      # Parser

      define "P0001", "unexpected token", "Expected %{expected}.", <<~TEXT, title: "expected %{expected}", label: "expected %{expected} here"
        The parser found something other than what the grammar allows at this point. The message names what it
        expected: a `;` at the end of a statement, a name, a number, a type.

            message A {
              int32 a = 1
              int32 b = 2;
            }

        A missing `;` is reported at the start of the next statement, so look at the end of the previous line too.
      TEXT

      define "P0201", "no syntax or edition statement",
        "File must begin with an edition or syntax statement, e.g. 'edition = \"2023\";'.", <<~TEXT
          This parser was told to require a `syntax` or `edition` statement, and the file has none.

          Start the file with `edition = "2023";`, or `syntax = "proto3";` for proto3.
        TEXT

      define "P0202", "unknown syntax or edition",
        ["Expected syntax identifier.", "Unrecognized syntax identifier \"%{syntax}\".  This parser only recognizes \"proto2\" and \"proto3\".",
          "Unknown edition \"%{edition}\"."], <<~TEXT, label: "not a known syntax or edition"
            `syntax` takes `"proto2"` or `"proto3"`; `edition` takes an edition year protoc knows, like `"2023"` or
            `"2024"`.

                syntax = "proto4";

            Use one of the supported values.
          TEXT

      define "P0203", "not a top-level statement", "Expected top-level statement (e.g. \"message\").", <<~TEXT,
        At the top of a file only `syntax`, `edition`, `package`, `import`, `option`, `message`, `enum`, `service`
        and `extend` can start a statement.

            mesage A {}

        Check the spelling of the keyword; a stray `}` or `;` from a previous edit causes this too.
      TEXT
        title: "expected a top-level statement", label: "not `message`, `enum`, `service`, `extend`, `import`, `option` or `package`"

      define "P0204", "unmatched brace", "Unmatched \"}\".", <<~TEXT, title: "unmatched `}`", label: "no `{` to close"
        A `}` at the top level of the file closes nothing.

            message A {}
            }

        Remove it, or find the `{` it was meant to close.
      TEXT

      define "P0205", "unclosed block", "Reached end of input in %{what} (missing '}').", <<~TEXT,
        The file ends inside a `message`, `enum`, `service`, `oneof`, `extend` or options block.

            message A {
              int32 a = 1;

        Add the missing `}`.
      TEXT
        title: "end of file inside %{what}", label: "expected `}`", help: "add the missing `}`"

      define "P0206", "two package statements", "Multiple package definitions.", <<~TEXT, label: "second `package`"
        A file has one package. Every type in it is named under that package.

            package a;
            package b;

        Keep one; split the file if the types belong to two packages.
      TEXT

      define "P0207", "bad import", "Expected a string naming the file to import.", <<~TEXT, label: "expected a quoted file name"
        `import` takes a quoted path, relative to an include path.

            import foo/bar.proto;

        Quote it: `import "foo/bar.proto";`.
      TEXT

      define "P0208", "misplaced visibility", "'local' and 'export' visibility modifiers are valid only on 'message' and 'enum'",
        <<~TEXT, label: "not before `message` or `enum`"
          Edition 2024's `export` and `local` modifiers apply to messages and enums only.

              export service S {}

          Remove the modifier.
        TEXT

      define "P0209", "nesting too deep", "Reached maximum recursion limit for nested messages.", <<~TEXT
        Messages are nested more than 32 levels deep. protoc stops there to bound its recursion.

        Move inner messages to the top level; nothing about the wire format needs the nesting.
      TEXT

      define "P0210", "import kind not allowed here",
        ["option import is not supported before edition 2024.",
          "imports should precede any option imports to ensure proto files can roundtrip.",
          "weak import is not supported in edition 2024 and above. Consider using option import instead."],
        <<~TEXT, label: "here"
          `import option` arrived in edition 2024, which also dropped `import weak`; plain imports come before
          option imports.

              edition = "2023";
              import option "acme/options.proto";

          Move the file to edition 2024 for option imports, use `import option` instead of `import weak` there, and
          list plain imports first.
        TEXT

      define "P0301", "missing label", "Expected \"required\", \"optional\", or \"repeated\".", <<~TEXT,
        In proto2 every field needs a label.

            syntax = "proto2";
            message A { int32 a = 1; }

        Write `optional int32 a = 1;` (or `repeated`). Do not reach for `required`: see
        `protostar lint --explain FIELD_NOT_REQUIRED`.
      TEXT
        title: "proto2 fields need a label", label: "expected `optional` or `repeated`", help: "add `optional`"

      define "P0302", "missing field number", ["Missing field number.", "Expected field number."], <<~TEXT,
        Every field needs `= N` with its field number, the number on the wire.

            message A { int32 a; }

        Add the next unused number: `int32 a = 1;`.
      TEXT
        title: "missing field number", label: "expected `= <number>`"

      define "P0303", "number out of range", ["Field number out of bounds.", "Integer out of range."], <<~TEXT,
        The number does not fit: field numbers go up to 536,870,911, enum values are 32-bit signed integers.

            enum E { A = 0; B = 4294967296; }

        Use a smaller number.
      TEXT
        label: "out of range"

      define "P0304", "malformed group", ["Group names must start with a capital letter.", "Missing group body."], <<~TEXT
        A proto2 `group` declares a field and a message type at once; the type name must be capitalised and the body
        follow in braces.

            optional group result = 1 { optional string url = 2; }

        Capitalise the name (`group Result`). Better, do not use groups: see `protostar lint --explain NO_GROUPS`.
      TEXT

      define "P0305", "map field misuse",
        ["Map fields are not allowed in oneofs.", "Field labels (required/optional/repeated) are not allowed on map fields.",
          "Map fields are not allowed to be extensions."], <<~TEXT
            A `map<K, V>` field is a repeated field of a synthetic entry message: it cannot have a label, sit in a
            `oneof`, or be an extension.

                repeated map<string, int32> counts = 1;

            Drop the label; for a map in a oneof, wrap it in a message.
          TEXT

      define "P0306", "label in a oneof", "Fields in oneofs must not have labels (required / optional / repeated).",
        <<~TEXT, label: "remove the label", help: "oneof members are always optional; to repeat one, wrap it in a message"
          Members of a `oneof` are optional by construction and cannot be repeated.

              oneof kind { optional string name = 1; }

          Remove the label.
        TEXT

      define "P0307", "proto2 syntax in an editions file",
        ["Label \"optional\" is not supported in editions. By default, all singular fields have presence unless features.field_presence is set.",
          "Label \"required\" is not supported in editions, use features.field_presence = LEGACY_REQUIRED.",
          "Group syntax is no longer supported in editions. To get group behavior you can specify features.message_encoding = DELIMITED on a message field."],
        <<~TEXT
          Editions replace labels and groups with features. Singular fields have presence by default, `required` is
          `features.field_presence = LEGACY_REQUIRED`, and a group is a message field with
          `features.message_encoding = DELIMITED`.

              edition = "2023";
              message A { optional int32 a = 1; }

          Drop `optional`; spell the other two as features.
        TEXT

      define "P0308", "obsolete type name", "Type '%{old}' is obsolete in unstable editions, use '%{new}' instead.",
        <<~TEXT, label: "obsolete", help: "write `%{new}`"
          In the unstable edition the integer types were renamed, and the old spelling means something else.

          Use the spelling the message suggests.
        TEXT

      define "P0309", "bad default or json_name",
        ["Already set option \"default\".", "Already set option \"json_name\".", "Expected integer for field default value.",
          "Unsigned field can't have negative default value.", "Expected string for field default value.",
          "Expected enum identifier for field default value.", "Expected string for JSON name.",
          "Messages can't have default values."], <<~TEXT, label: "here"
            `default` and `json_name` are written once per field, and the default must be a value of the field's type:
            a number for numbers, a quoted string for strings and bytes, a value name for enums. Message fields have no
            default.

                optional uint32 a = 1 [default = -1];

            Fix the value, or remove the duplicate.
          TEXT

      define "P0401", "unterminated option value",
        ["Unexpected end of stream while parsing aggregate value.", "Unexpected end of stream while parsing option value."],
        <<~TEXT
          The file ends inside an option value, usually an aggregate `{ ... }` that is never closed.

          Close the braces.
        TEXT

      define "P0402", "bad negative value", ["Identifier after '-' symbol must be inf or nan.", "Invalid '-' symbol before string."],
        <<~TEXT, label: "here"
          A minus sign can only precede a number, `inf` or `nan`.

              option (x) = -foo;

          Remove the `-`, or use a number.
        TEXT

      define "P0403", "missing option value", "Expected option value.", <<~TEXT, label: "expected a value"
        An option needs a value after `=`: a number, a string, an identifier or an aggregate in braces.

            option java_package = ;

        Write the value.
      TEXT

      define "P0501", "bad reserved or extensions range",
        ["Expected field number range.", "Expected field name or number range.", "Expected enum value or number range.",
          "Expected enum number range."], <<~TEXT, label: "expected a number or range"
            `reserved` and `extensions` take numbers and ranges (`2, 15, 9 to 11, 40 to max`); `reserved` also takes
            names.

                extensions foo;

            Write numbers or ranges.
          TEXT

      define "P0502", "reserved names spelt for the wrong syntax",
        ["Reserved names must be identifiers in editions, not string literals.",
          "Reserved names must be string literals. (Only editions supports identifiers.)",
          "Expected enum value string literal.", "Expected field name string literal.", "Expected enum value identifier.",
          "Expected field name identifier."], <<~TEXT, label: "here"
            Before editions reserved names are quoted strings; under editions they are bare identifiers.

                syntax = "proto3";
                message A { reserved foo; }

            Write `reserved "foo";` in proto2 and proto3, `reserved foo;` in editions.
          TEXT

      define "P0503", "reserved name is not an identifier", "Reserved name \"%{name}\" is not a valid identifier.",
        <<~TEXT, label: "not an identifier"
          A reserved name must be a name a field or value could have.

              reserved "foo bar";

          Fix the spelling.
        TEXT

      define "P0601", "pointless allow_alias",
        ["\"%{enum}\" declares 'option allow_alias = false;' which has no effect. Please remove the declaration.",
          "\"%{enum}\" declares support for enum aliases but no enum values share field numbers. Please remove the unnecessary 'option allow_alias = true;' declaration."],
        <<~TEXT, help: "remove the `allow_alias` option"
          `allow_alias = false` is the default, and `allow_alias = true` with no two values sharing a number does
          nothing; protoc rejects both so the option means something when present.

              enum E { option allow_alias = true; A = 0; B = 1; }

          Remove the option.
        TEXT

      define "P0602", "enum value without a number", "Missing numeric value for enum constant.", <<~TEXT,
        Every enum value needs `= N`.

            enum Color { COLOR_UNSPECIFIED; }

        Write `COLOR_UNSPECIFIED = 0;`.
      TEXT
        label: "expected `= <number>`"

      # Linker: files and imports

      define "L0101", "file not found", "File not found.", <<~TEXT, help: "check the include paths (-I) and the spelling of the name"
        No include path has a file of that name. For a file named on the command line, the name is resolved against
        `-I` (or the file's own directory when there is none); for an import, against the include paths in order.

        Pass `-I` with the directory the import is relative to.
      TEXT

      define "L0102", "import failed",
        ["Import \"%{import}\" was not found or had errors.", "Import \"%{import}\" has not been loaded."], <<~TEXT,
          The imported file could not be found, or it could not be compiled; its own errors are reported above this
          one.

              import "acme/missing.proto";

          Fix the imported file's errors first, or the include path that should find it.
        TEXT
        title: "cannot import `%{import}`", label: "not found or has errors"

      define "L0103", "import listed twice", "Import \"%{import}\" was listed twice.", <<~TEXT, label: "second import", help: "remove one of the imports"
        The same file is imported twice.

            import "a.proto";
            import "a.proto";

        Remove the duplicate.
      TEXT

      define "L0104", "import cycle", "File recursively imports itself: %{chain}", <<~TEXT, title: "import cycle: %{chain}", label: "this import closes the cycle"
        Files cannot import each other in a cycle, directly or through others.

        Move the types both files need into a third file that both import.
      TEXT

      define "L0105", "file defined twice",
        ["A file with this name is already in the pool.", "file \"%{file}\" is already in the pool"], <<~TEXT
          A file of this name was already built. This happens when the same file is reachable under two names, or
          when a pool is reused.

          Name each file once, by one include path.
        TEXT

      define "L0106", "unsupported edition",
        ["Edition %{edition} is earlier than the minimum supported edition %{minimum}",
          "Edition %{edition} is later than the maximum supported edition %{maximum}"], <<~TEXT, label: "unsupported edition"
            The edition is outside the range this compiler (like protoc 36.2) supports.

            Use an edition between PROTO2 and 2026.
          TEXT

      # Linker: names

      define "L0201", "name already defined",
        ["\"%{name}\" is already defined in \"%{scope}\".", "\"%{name}\" is already defined.",
          "\"%{name}\" is already defined in file \"%{file}\".",
          "\"%{name}\" is already defined (as something other than a package) in file \"%{file}\".",
          "\"%{name}\" is already defined in file \"%{file}\" (redefined in \"%{other}\")",
          "\"%{name}\" is already defined as a package in file \"%{file}\" (redefined as a %{kind} in \"%{other}\")"],
        <<~TEXT, title: "`%{name}` is defined more than once", label: "redefined here"
          Two declarations have the same full name: two fields of one message, two messages in a package, or a type
          and a package. Fields, nested types, oneofs and enum values share one namespace per scope.

              message A {
                int32 id = 1;
                string id = 2;
              }

          Rename one of them.
        TEXT

      define "L0202", "enum values are siblings of their enum",
        "Note that enum values use C++ scoping rules, meaning that enum values are siblings of their type, not children of it.  Therefore, \"%{name}\" must be unique within %{scope}, not just within \"%{enum}\".",
        <<~TEXT, title: "enum value names are scoped like C++, not to their enum", help: "prefix the values with the enum's name, e.g. `%{enum}_%{name}`"
          An enum's values live in the scope that contains the enum, not inside it, so two enums in one package
          cannot both have `UNKNOWN`.

              enum A { UNKNOWN = 0; }
              enum B { UNKNOWN = 0; }

          Prefix each value with its enum's name: `A_UNKNOWN`, `B_UNKNOWN`. `ENUM_VALUE_PREFIX` checks for this.
        TEXT

      define "L0203", "name not defined", "\"%{name}\" is not defined.", <<~TEXT, title: "`%{name}` is not defined", label: "not found in this scope"
        No type, option or extension of that name is visible from here: it is misspelt, lives in a package you did
        not qualify, or its file is not imported.

            message A { Missing m = 1; }

        Check the spelling and package, and import the file that defines it.
      TEXT

      define "L0204", "name defined in a file not imported",
        "\"%{name}\" seems to be defined in \"%{file}\", which is not imported by \"%{importer}\".  To use it here, please add the necessary import.",
        <<~TEXT, title: "`%{name}` is defined in `%{file}`, which is not imported", label: "not imported", help: "add `import \"%{file}\";`"
          The name exists, but in a file this one does not import (directly or through `import public`).

          Add the import.
        TEXT

      define "L0205", "name resolved to the wrong scope",
        ["\"%{name}\" is resolved to \"%{resolved}\", which is not defined. The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., \".%{full}\") to start from the outermost scope.",
          "Option \"%{name}\" is resolved to \"(%{resolved})\", which is not defined. The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., \"(.%{full}\") to start from the outermost scope."],
        <<~TEXT, title: "`%{name}` resolves to `%{resolved}`, which is not defined", label: "resolves to `%{resolved}`", help: "write `.%{full}` to start from the outermost scope"
          Names resolve from the innermost scope out, and the first component that matches decides: once `foo` in
          `foo.Bar` matches a nested `foo`, the outer `foo` is never tried.

              package foo;
              message Bar {}
              message A {
                message foo {}
                foo.Bar b = 1;
              }

          Qualify the name fully with a leading dot: `.foo.Bar`.
        TEXT

      define "L0206", "wrong kind of type",
        ["\"%{name}\" is not a message type.", "\"%{name}\" is not a type.", "\"%{name}\" is not an enum type."], <<~TEXT,
          The name resolves, but to the wrong kind of thing: a field or package where a type is needed, an enum
          where an extendee must be a message.

              message A { int32 x = 1; }
              message B { A.x y = 1; }

          Point it at a type of the right kind.
        TEXT
        title: "`%{name}` is not the right kind of type", label: "wrong kind"

      define "L0207", "symbol not visible",
        "Symbol \"%{name}\", defined in \"%{file}\" %{why} is not visible from \"%{importer}\". %{reason} and cannot be accessed outside its own file",
        <<~TEXT, title: "`%{name}` is local to `%{file}`", label: "not visible here"
          Under edition 2024 a type marked `local`, or local by `default_symbol_visibility`, can only be used in its
          own file.

          Mark it `export`, or move what uses it into its file.
        TEXT

      # Linker: numbers and ranges

      define "L0301", "field number already used",
        ["Field number %{number} has already been used in \"%{scope}\" by field \"%{other}\". Next available field number is %{next}.",
          "Field number %{number} has already been used in \"%{scope}\" by field \"%{other}\". There are no available field numbers.",
          "Field number %{number} has already been used in \"%{scope}\" by field \"%{other}\". %{suggestion}."],
        <<~TEXT, title: "field number %{number} is already used in `%{scope}`", label: "reused here", help: "the next available field number is %{next}"
          Two fields of one message have the same number. The number is what goes on the wire, so it must be unique
          within the message.

              message A {
                int32 a = 1;
                int32 b = 1;
              }

          Give the new field the next free number. Do not reuse the number of a field you deleted: reserve it.
        TEXT

      define "L0302", "extension number already used",
        ["Extension number %{number} has already been used in \"%{scope}\" by extension \"%{other}\".",
          "extension number %{number} of \"%{scope}\" is already used by \"%{other}\" (redefined by \"%{name}\")"],
        <<~TEXT, title: "extension number %{number} of `%{scope}` is already used", label: "reused here"
          Two extensions of one message use the same number.

          Pick another number inside the message's extension ranges.
        TEXT

      define "L0303", "extension number used in another file",
        "Extension number %{number} has already been used in \"%{scope}\" by extension \"%{other}\" defined in %{file}.",
        <<~TEXT, title: "extension number %{number} of `%{scope}` is already used in %{file}", label: "also used in %{file}"
          Another file already extends this message with this number. Both cannot be linked into one program.

          Pick a number no other file uses; for options, register one with the protobuf global extension registry.
        TEXT

      define "L0304", "number not positive",
        ["Field numbers must be positive integers.", "Extension numbers must be positive integers.",
          "Reserved numbers must be positive integers."], <<~TEXT, label: "must be 1 or more"
            Field, extension and reserved numbers start at 1.

                message A { int32 a = 0; }

            Use 1 or more.
          TEXT

      define "L0305", "number too large",
        ["Field numbers cannot be greater than %{max}.", "Extension numbers cannot be greater than %{max}."],
        <<~TEXT, label: "greater than %{max}"
          Field numbers have 29 bits on the wire: the largest is 536,870,911 (2,147,483,647 for MessageSet
          extensions).

          Use a smaller number. Numbers 1 to 15 take one byte on the wire, so give them to the most common fields.
        TEXT

      define "L0306", "empty range",
        ["Extension range end number must be greater than start number.", "Reserved range end number must be greater than start number."],
        <<~TEXT, label: "end is not after start"
          A range `a to b` needs `b` at least `a`.

              reserved 10 to 5;

          Swap the ends.
        TEXT

      define "L0307", "overlapping ranges",
        ["Reserved range %{start} to %{end} overlaps with already-defined range %{other_start} to %{other_end}.",
          "Extension range %{start} to %{end} overlaps with reserved range %{other_start} to %{other_end}.",
          "Extension range %{start} to %{end} overlaps with already-defined range %{other_start} to %{other_end}."],
        <<~TEXT, title: "range %{start} to %{end} overlaps %{other_start} to %{other_end}", label: "overlaps"
          Reserved and extension ranges of one message cannot overlap each other.

              extensions 100 to 199;
              reserved 150 to 160;

          Make the ranges disjoint.
        TEXT

      define "L0308", "extension range includes a field", "Extension range %{start} to %{end} includes field \"%{field}\" (%{number}).",
        <<~TEXT, title: "extension range %{start} to %{end} includes field `%{field}`", label: "this range"
          A field's number falls inside one of the message's extension ranges.

          Move the field or shrink the range.
        TEXT

      define "L0309", "reserved number used",
        ["Field \"%{name}\" uses reserved number %{number}.", "Enum value \"%{name}\" uses reserved number %{number}."],
        <<~TEXT, title: "`%{name}` uses reserved number %{number}", label: "reserved here", help: "give `%{name}` a number that is not reserved"
          The number was reserved, usually because a field or value that had it was deleted. Reusing it would make
          old data decode as the new field.

              message A {
                reserved 2;
                int32 b = 2;
              }

          Use another number.
        TEXT

      define "L0310", "reserved name used", ["Field name \"%{name}\" is reserved.", "Enum value \"%{name}\" is reserved."],
        <<~TEXT, title: "`%{name}` is a reserved name", label: "reserved"
          The name was reserved, usually because a field or value of that name was deleted; the JSON and text formats
          would read old data into the new field.

          Use another name.
        TEXT

      define "L0311", "name reserved twice",
        ["Field name \"%{name}\" is reserved multiple times.", "Enum value \"%{name}\" is reserved multiple times."],
        <<~TEXT, label: "reserved again", help: "remove the duplicate"
          A name appears twice in `reserved`.

          Remove the duplicate.
        TEXT

      define "L0312", "suggested field numbers", "Suggested field numbers for %{message}: %{numbers}", <<~TEXT,
        Follows a field number error: these numbers are free in the message.
      TEXT
        title: "free field numbers in `%{message}`: %{numbers}"

      # Linker: fields

      define "L0401", "required extension", ["The extension %{name} cannot be required.", "Extensions can't be required."],
        <<~TEXT, label: "required"
          Extensions cannot be `required`: a reader that does not know the extension could never check it.

          Make it `optional`.
        TEXT

      define "L0402", "bad default value",
        ["Repeated fields can't have default values.", "Boolean default must be true or false.",
          "Invalid escaping in default value.", "Default value for an enum field must be an identifier.",
          "Enum type \"%{enum}\" has no value named \"%{value}\"."], <<~TEXT, label: "here"
            The `default` does not fit the field: repeated fields have none, booleans take `true` or `false`, enums take
            one of their value names.

                optional Color c = 1 [default = PURPLE];

            Fix the value or remove the default.
          TEXT

      define "L0403", "empty enum or oneof", ["Enums must contain at least one value.", "Oneof must have at least one field."],
        <<~TEXT
          An enum needs at least one value and a oneof at least one field.

              enum E {}

          Add one, or remove the declaration.
        TEXT

      define "L0404", "oneof fields not together",
        "Fields in the same oneof must be defined consecutively. \"%{field}\" cannot be defined before the completion of the \"%{oneof}\" oneof definition.",
        <<~TEXT, title: "oneof `%{oneof}` is interrupted by `%{field}`"
          The members of a oneof are written together inside its braces.

          Move the field out of the middle of the oneof.
        TEXT

      define "L0405", "labelled oneof member", "Fields of oneofs must themselves have label LABEL_OPTIONAL.", <<~TEXT
        A descriptor put a oneof member under a label other than optional. Only hand-built descriptors can do this.
      TEXT

      define "L0406", "not an extension number", "\"%{extendee}\" does not declare %{number} as an extension number.",
        <<~TEXT, title: "`%{extendee}` has no extension range for %{number}", label: "outside the extension ranges"
          An extension's number must fall inside one of the extended message's `extensions` ranges.

              message A { extensions 100 to 199; }
              extend A { optional int32 x = 5; }

          Use a number from the ranges, or widen them.
        TEXT

      define "L0407", "features outside editions",
        ["Features are only valid under editions.", "Feature field `%{feature}` must resolve to a known value, found %{value}"],
        <<~TEXT, label: "here"
          `features` options only exist in editions files, and must be set to a known value.

              syntax = "proto3";
              option features.field_presence = EXPLICIT;

          Move the file to editions, or remove the option.
        TEXT

      # Linker: options

      define "L0501", "malformed option name", ["Option must have a name.", "Option must not use reserved name \"uninterpreted_option\"."],
        <<~TEXT, label: "here"
          The option has no name, or uses the name protobuf keeps for its own bookkeeping.

          Name a real option.
        TEXT

      define "L0502", "unknown option",
        "Option \"%{name}\" unknown. Ensure that your proto definition file imports the proto which defines the option (i.e. via import option after edition 2024).",
        <<~TEXT, title: "unknown option `%{name}`", label: "unknown option", help: "import the file that defines `%{name}`"
          No option of that name is visible. Built-in options are fields of the `*Options` messages in
          descriptor.proto; custom options, written in parentheses, are extensions declared in some file.

              option (acme.retention_days) = 30;

          Check the spelling, and import the file that declares the extension.
        TEXT

      define "L0503", "not a field of the option",
        ["Option field \"%{name}\" is not a field or extension of message \"%{message}\".",
          "Option \"%{name}\" is an atomic type, not a message.",
          "Option field \"%{name}\" is a repeated message. Repeated message options must be initialized using an aggregate value."],
        <<~TEXT, label: "here"
          The option path goes through something that does not have that field: `(opt).a.b` needs `a` to be a
          singular message with a field `b`.

          Fix the path, or set the whole value with an aggregate: `option (opt) = { a: { b: 1 } };`.
        TEXT

      define "L0504", "feature used in its own file", "Feature \"%{name}\" can't be used in the same file it's defined in.",
        <<~TEXT, label: "defined in this file"
          A custom feature cannot be used by the file that declares it.

          Move the declaration to a file of its own and import it.
        TEXT

      define "L0505", "option set twice", "Option \"%{name}\" was already set.", <<~TEXT, title: "option `%{name}` is set twice", label: "set again", help: "remove one of them"
        The same option is set twice on one element.

        Remove the duplicate.
      TEXT

      define "L0506", "option value of the wrong type",
        ["Value must be number for %{type} option \"%{name}\".", "Value must be identifier for boolean option \"%{name}\".",
          "Value must be \"true\" or \"false\" for boolean option \"%{name}\".",
          "Value must be identifier for enum-valued option \"%{name}\".",
          "Value must be quoted string for string option \"%{name}\".",
          "Option \"%{name}\" is a message. To set the entire message, use syntax like \"%{a} = { <proto text format> }\". To set fields within it, use syntax like \"%{b}.foo = value\"."],
        <<~TEXT, label: "wrong type"
          The value does not fit the option's type: numbers for numeric options, `true` or `false` for booleans, a
          value name for enums, a quoted string for strings, an aggregate `{ ... }` for messages.

              option java_multiple_files = "yes";

          Write a value of the option's type.
        TEXT

      define "L0507", "option value out of range",
        ["Value out of range, %{min} to %{max}, for %{type} option \"%{name}\".",
          "Value must be integer, from %{min} to %{max}, for %{type} option \"%{name}\"."],
        <<~TEXT, label: "out of range", help: "use an integer from %{min} to %{max}"
          The number does not fit the option's integer type.

          Use a value inside the range.
        TEXT

      define "L0508", "no such enum value for an option",
        ["Enum type \"%{enum}\" has no value named \"%{value}\" for option \"%{name}\". This appears to be a value from a sibling type.",
          "Enum type \"%{enum}\" has no value named \"%{value}\" for option \"%{name}\"."],
        <<~TEXT, title: "`%{enum}` has no value `%{value}`", label: "not a value of `%{enum}`"
          The option is enum-valued, and the value is not one of the enum's.

              option optimize_for = FAST;

          Use one of the enum's values (`SPEED`, `CODE_SIZE` or `LITE_RUNTIME` here).
        TEXT

      define "L0509", "bad aggregate option value", "Error while parsing option value for \"%{name}\": %{error}",
        <<~TEXT, title: "cannot parse the value of `%{name}`", label: "%{error}"
          An aggregate option value `{ ... }` is protobuf text format for the option's message type, and it does not
          parse: an unknown field, a value of the wrong type, a missing brace.

              option (limits) = { max: "ten" };

          Fix the text-format value; the message after the colon says what is wrong.
        TEXT

      # Validator: proto3 and enums

      define "V0101", "extensions in proto3",
        ["Extension ranges are not allowed in proto3.", "Extensions in proto3 are only allowed for defining options."],
        <<~TEXT, label: "not in proto3"
          proto3 has no extension ranges, and extends only the `*Options` messages to declare custom options. Use
          `google.protobuf.Any`, or editions, for open-ended data.

          Remove the range or the extension, or move the file to editions.
        TEXT

      define "V0102", "MessageSet in proto3", "MessageSet is not supported in proto3.", <<~TEXT, label: "message_set_wire_format"
        `message_set_wire_format` is a proto2 legacy option.

        Remove it, or keep the message in a proto2 file.
      TEXT

      define "V0103", "required in proto3", "Required fields are not allowed in proto3.", <<~TEXT, label: "required", help: "remove `required`"
        proto3 has no `required` fields: they made schemas impossible to evolve (see
        `protostar lint --explain FIELD_NOT_REQUIRED`).

        Remove the label and validate presence in code.
      TEXT

      define "V0104", "default in proto3", "Explicit default values are not allowed in proto3.", <<~TEXT, label: "default", help: "remove the `default`"
        In proto3 the default is always the type's zero value.

            int32 retries = 1 [default = 3];

        Remove the option and apply the default in code.
      TEXT

      define "V0105", "closed enum in proto3",
        "Enum type \"%{enum}\" is not an open enum, but is used in \"%{message}\" which is a proto3 message type.",
        <<~TEXT, title: "closed enum `%{enum}` used in proto3 message `%{message}`", label: "closed enum"
          proto3 messages can only use open enums; proto2 enums are closed, and drop unknown values.

          Define the enum in a proto3 or editions file, or keep the message in proto2.
        TEXT

      define "V0106", "groups in proto3", "Groups are not supported in proto3 syntax.", <<~TEXT, label: "group"
        proto3 has no groups.

        Declare a message type and a field of that type.
      TEXT

      define "V0107", "first enum value not zero", "The first enum value must be zero for open enums.", <<~TEXT,
        In proto3 and open editions enums the first value must be 0: it is the default every reader sees for an
        unset field and for numbers it does not know.

            enum Color { RED = 1; }

        Add a first value `COLOR_UNSPECIFIED = 0;`.
      TEXT
        title: "the first value of an open enum must be zero", label: "not zero", help: "add `UNSPECIFIED = 0;` as the first value"

      define "V0108", "duplicate enum value number",
        "\"%{name}\" uses the same enum value as \"%{first}\". If this is intended, set 'option allow_alias = true;' to the enum definition.%{next}",
        <<~TEXT, title: "`%{name}` reuses the number of `%{first}`", label: "reused here", help: "set `option allow_alias = true;` if the alias is intended"
          Two values of one enum have the same number. That is an alias, and has to be asked for.

              enum Status { OK = 0; SUCCESS = 0; }

          Give the value its own number, or add `option allow_alias = true;`.
        TEXT

      define "V0109", "enum values clash in JSON",
        "Enum name %{name} has the same name as %{other} if you ignore case and strip out the enum name prefix (if any). (If you are using allow_alias, please assign the same number to each enum value name.)",
        <<~TEXT, title: "`%{name}` and `%{other}` clash once the prefix is stripped", label: "clashes with `%{other}`"
          Some generators strip the enum's name as a prefix and change case, which makes these two values the same.

          Rename one of them.
        TEXT

      define "V0110", "import kind not allowed in this edition",
        ["option imports are not supported before edition 2024.", "weak imports are not allowed under edition 2024 and beyond."],
        <<~TEXT, label: "here"
          `import option` needs edition 2024 or later, and `import weak` is gone from edition 2024 on.

          Use plain imports before edition 2024 and `import option` from it on.
        TEXT

      define "V0201", "invalid json_name",
        "The custom JSON name of field \"%{field}\" (\"%{name}\") is invalid: JSON names may not start with '[' and end with ']'.",
        <<~TEXT, label: "invalid"
          `[name]` in JSON is how extensions are written, so a field cannot claim it.

          Choose another `json_name`.
        TEXT

      define "V0203", "json_name not allowed",
        ["option json_name is not allowed on extension fields.", "json_name cannot have embedded null characters."],
        <<~TEXT, label: "json_name"
          Extensions are written in JSON as `[full.name]`, so they take no `json_name`; and a JSON name cannot contain
          a NUL character.

          Remove the option, or the NUL.
        TEXT

      define "V0202", "JSON names clash",
        "The %{kind} JSON name of field \"%{field}\" (\"%{name}\") conflicts with the %{other_kind} JSON name of field \"%{other}\"%{suffix}.",
        <<~TEXT, title: "`%{field}` and `%{other}` have the same JSON name `%{name}`", label: "clashes"
          Two fields of one message map to the same JSON key, so JSON could not tell them apart. The default JSON
          name is the field name in lowerCamelCase: `foo_bar` and `fooBar` are both `fooBar`.

              message A {
                int32 foo_bar = 1;
                int32 fooBar = 2;
              }

          Rename one field (fields are lower_snake_case), or give one a distinct `json_name`.
        TEXT

      # Validator: extensions

      define "V0301", "unverified range with declarations",
        "Cannot mark the extension range as UNVERIFIED when it has extension(s) declared.", <<~TEXT
          An extension range with `declaration`s is verified by definition.

          Remove `verification = UNVERIFIED`, or the declarations.
        TEXT

      define "V0302", "bad extension declaration",
        ["Extension declaration number %{number} is not in the extension range.",
          "Extension declaration number %{number} is declared multiple times.",
          "Extension declaration #%{number} should have both \"full_name\" and \"type\" set.",
          "Extension field name \"%{name}\" is declared multiple times.",
          "\"%{name}\" must have a leading dot to indicate the fully-qualified scope.",
          "\"%{name}\" contains invalid identifiers."], <<~TEXT
            An extension range's `declaration`s must each name a number inside the range once, with a fully
            qualified `full_name` (leading dot) and a `type`.

            Fix the declaration.
          TEXT

      define "V0303", "extension does not match its declaration",
        ["Cannot use number %{number} for extension field %{field}, as it is reserved in the extension declarations for message %{message}.",
          "Missing extension declaration for field %{field} with number %{number} in extendee message %{message}. An extension range must declare for all extension fields if its verification state is DECLARATION or there's any declaration in the range already. Otherwise, consider splitting up the range.",
          "\"%{extendee}\" extension field %{number} is expected to be type \"%{type}\", not \"%{actual}\".",
          "\"%{extendee}\" extension field %{number} is expected to have field name \"%{name}\", not \"%{actual}\".",
          "\"%{extendee}\" extension field %{number} is expected to be %{label}."], <<~TEXT
            The extended message declares which extensions may use its numbers, and this one does not match: the
            number is reserved, undeclared, or declared with another name, type or label.

            Use the declared name, type and label, or another number.
          TEXT

      define "V0304", "MessageSet misuse",
        ["Extensions of MessageSets must be optional messages.", "MessageSets cannot have fields, only extensions."],
        <<~TEXT
          A MessageSet holds only optional message extensions.

          Remove the field, or make the extension an optional message.
        TEXT

      define "V0305", "lite runtime mismatch",
        ["Extensions to non-lite types can only be declared in non-lite files.  Note that you cannot extend a non-lite type to contain a lite type, but the reverse is allowed.",
          "Files that do not use optimize_for = LITE_RUNTIME cannot import files which do use this option.  This file is not lite, but it imports \"%{import}\" which is.",
          "Files with optimize_for = LITE_RUNTIME cannot define services unless you set both options cc_generic_services and java_generic_services to false."],
        <<~TEXT
          `optimize_for = LITE_RUNTIME` files generate code for the lite runtime, which full-runtime files cannot
          depend on.

          Use the same `optimize_for` in files that depend on each other.
        TEXT

      # Validator: options and features

      define "V0401", "lazy on the wrong field",
        ["[lazy = true] can only be specified for submessage fields.", "Extensions cannot be marked as unverified_lazy."],
        <<~TEXT, label: "lazy"
          Only message fields can be parsed lazily.

          Remove the option.
        TEXT

      define "V0402", "packed on the wrong field", "[packed = true] can only be specified for repeated primitive fields.",
        <<~TEXT, label: "packed"
          Only repeated numeric, enum and bool fields can be packed.

          Remove the option.
        TEXT

      define "V0403", "jstype on the wrong field",
        ["Illegal jstype for int64, uint64, sint64, fixed64 or sfixed64 field: %{jstype}",
          "jstype is only allowed on int64, uint64, sint64, fixed64 or sfixed64 fields."], <<~TEXT, label: "jstype"
            `jstype` chooses how JavaScript represents a 64-bit integer field, and applies to nothing else.

            Remove the option.
          TEXT

      define "V0404", "option on the wrong element", "Option %{option} cannot be set on an entity of type `%{type}`.",
        <<~TEXT, title: "option `%{option}` cannot be set on a %{type}"
          The option's declaration lists the kinds of element it may be set on (`targets`), and this is not one.

          Move the option to an element it targets.
        TEXT

      define "V0405", "ctype under edition 2024",
        "ctype option is not allowed under edition 2024 and beyond. Use the feature string_type = VIEW|CORD|STRING|... instead.",
        <<~TEXT, label: "ctype"
          From edition 2024 the C++ string type is a feature.

          Write `[features.(pb.cpp).string_type = CORD]` instead.
        TEXT

      define "V0501", "proto2 construct in editions",
        ["Required label is not allowed under editions.  Use the feature field_presence = LEGACY_REQUIRED to control this behavior.",
          "Group types are not allowed under editions.  Use the feature message_encoding = DELIMITED to control this behavior.",
          "Field option packed is not allowed under editions.  Use the repeated_field_encoding feature to control this behavior.",
          "File option java_string_check_utf8 is not allowed under editions. Use the (pb.java).utf8_validation feature to control this behavior."],
        <<~TEXT, label: "here"
          Under editions these behaviours are features rather than labels and options.

          Use the feature the message names.
        TEXT

      define "V0502", "field presence feature misuse",
        ["Required presence can't be specified by default.", "Implicit presence fields can't specify defaults.",
          "Implicit presence enum fields must always be open.", "Oneof fields can't specify field presence.",
          "Repeated fields can't specify field presence.", "Extensions can't specify field presence.",
          "Message fields can't specify implicit presence."], <<~TEXT, label: "here"
            `field_presence` applies to singular, non-oneof, non-extension fields; `IMPLICIT` presence has no defaults,
            does not work for messages, and needs open enums; `LEGACY_REQUIRED` cannot be a file default.

            Remove the feature from this field.
          TEXT

      define "V0503", "encoding feature on the wrong field",
        ["Only repeated fields can specify repeated field encoding.", "Only string fields can specify utf8 validation.",
          "Only repeated primitive fields can specify PACKED repeated field encoding.",
          "Only message fields can specify message encoding."], <<~TEXT, label: "here"
            Each encoding feature applies to one kind of field.

            Remove the feature from this field.
          TEXT

      define "V0504", "bad feature support declaration",
        ["%{name} was deprecated before it was introduced.", "%{name} is deprecated but does not specify a deprecation warning.",
          "%{name} specifies a deprecation warning but is not marked deprecated in any edition.",
          "%{name} was deprecated after it was removed.", "%{name} was removed before it was introduced.",
          "%{name} has been removed but does not specify a removal error.",
          "%{name} specifies a removal error but is not marked removed in any edition."], <<~TEXT
            A feature's `feature_support` must be consistent: introduced, then deprecated with a warning, then removed
            with an error.

            Fix the declaration's editions and messages.
          TEXT

      define "V0505", "feature not yet introduced",
        "%{name} wasn't introduced until edition %{introduced} and can't be used in edition %{edition}", <<~TEXT,
          The feature or option is newer than the file's edition.

          Move the file to that edition or a later one, or remove it.
        TEXT
        title: "`%{name}` needs edition %{introduced}", label: "not in edition %{edition}"

      define "V0506", "feature removed", "%{name} has been removed in edition %{removed}%{reason}", <<~TEXT,
        The feature or option was removed in the file's edition.

        Remove it; the removal message says what replaces it.
      TEXT
        title: "`%{name}` was removed in edition %{removed}", label: "removed"

      define "V0507", "feature deprecated", "%{name} has been deprecated in edition %{deprecated}: %{reason}", <<~TEXT,
        The feature or option is deprecated in the file's edition and will be removed in a later one.

        Follow the deprecation message. `NO_DEPRECATED_FEATURES` is the lint rule for these.
      TEXT
        title: "`%{name}` is deprecated since edition %{deprecated}", label: "deprecated", note: "%{reason}"

      define "V0508", "edition too new",
        "is a file using edition %{edition}, which is later than the protoc maximum supported edition 2026.", <<~TEXT
          The file uses an edition newer than protoc 36.2 supports.

          Use edition 2026 or earlier.
        TEXT

      define "V0601", "map entry misuse",
        ["map_entry should not be set explicitly. Use map<KeyType, ValueType> instead.",
          "Groups cannot be map entries. Use a regular message field with map<KeyType, ValueType> syntax instead.",
          "%{type} is a synthetic MapEntry message type, which is not allowed to be used as a field type.%{hint}"],
        <<~TEXT, label: "here"
          Map entry messages are made by the compiler for `map<K, V>` fields; they cannot be written or used by hand.

              message A { map<string, int32> m = 1; MEntry e = 2; }

          Use `map<K, V>`.
        TEXT

      define "V0602", "bad map key", ["Key in map fields cannot be enum types.", "Key in map fields cannot be float/double, bytes or message types."],
        <<~TEXT, label: "invalid key type", help: "use a string or integer key"
          Map keys are integers, bools or strings.

              map<Color, int32> counts = 1;

          Use a string or integer key; for enums, the value's name or number.
        TEXT

      define "V0603", "map enum value without zero", "Enum value in map must define 0 as the first value.", <<~TEXT, label: "enum"
        A map value that is an enum needs 0 as its first value, the value a missing entry reads as.

        Add a zero value first.
      TEXT

      define "V0604", "map entry name clash", "Expanded map entry type %{type} conflicts with an existing %{what}.",
        <<~TEXT, title: "map entry `%{type}` clashes with an existing %{what}"
          A `map<K, V> foo_bar` field makes a nested message `FooBarEntry`, and the message already has something of
          that name.

          Rename the field or the other declaration.
        TEXT

      # Validator: protoc's command-line checks

      define "V0701", "naming style",
        ["Package name %{name} %{problem}", "%{kind} name %{name} %{problem}", "Enum value name %{name} %{problem}"],
        <<~TEXT, label: "here"
          The file opted into `features.enforce_naming_style` (STYLE2024, the default from edition 2024): packages
          and fields lower_snake_case, messages, enums, services and methods TitleCase, enum values
          UPPER_SNAKE_CASE.

              edition = "2024";
              message user_profile {}

          Rename, or opt out with `option features.enforce_naming_style = STYLE_LEGACY;`.
        TEXT

      define "V0702", "proto limits",
        ["Message name %{name} should not contain more than %{limit} fields%{rest}",
          "Message name %{name} should not contain more than %{limit} oneofs%{rest}",
          "Oneof name %{name} should not contain more than %{limit} fields%{rest}",
          "Enum name %{name} should not contain more than %{limit} values%{rest}"], <<~TEXT, label: "too large"
            Edition 2024 limits how many fields, oneofs and values one message, oneof or enum may have.

            Split it, or opt out with `option features.enforce_proto_limits = LEGACY_NO_EXPLICIT_LIMITS;`.
          TEXT

      define "V0703", "unused import", "Import %{import} is unused.", <<~TEXT,
        Nothing in the file uses a name from the imported file. Unused imports slow builds and hide real
        dependencies.

        Remove the import. `IMPORT_USED` is the lint rule for these.
      TEXT
        title: "unused import `%{import}`", label: "unused", help: "remove the import"

      define "V0704", "generic services",
        "Generic services (cc_generic_services, java_generic_services, and py_generic_services) are deprecated in favor of using plugins that generate code specific to your particular RPC system. Additional code generator options may be required to enable generic services and total removal of these options is planned in future breaking releases.",
        <<~TEXT, title: "generic services are deprecated", help: "remove the *_generic_services options and use a gRPC plugin"
          The `*_generic_services` options generate RPC stubs that no RPC system uses any more.

          Remove the options and generate stubs with your RPC system's plugin.
        TEXT

      define "V0705", "reserved field numbers",
        "Field numbers 19000 through 19999 are reserved for the protocol buffer library implementation.", <<~TEXT
          Numbers 19000 to 19999 belong to the protobuf implementation.

          Use another number.
        TEXT

      define "V0706", "export of a nested type",
        ["\"%{name}\" is a nested message and cannot be `export` with STRICT default_symbol_visibility. It must be moved to top-level, ideally in its own file in order to be `export`.",
          "\"%{name}\" is a nested enum and cannot be marked `export` with STRICT default_symbol_visibility. It must be moved to top-level, ideally in its own file in order to be `export`. For C++ namespacing of enums in a messages use: `local message <OuterNamespace> { export enum %{enum} {...} reserved 1 to max; }`"],
        <<~TEXT, title: "nested `%{name}` cannot be exported under STRICT visibility"
          With `default_symbol_visibility = STRICT` only top-level types can be exported.

          Move the type to the top level.
        TEXT

      ENTRIES.freeze
      BY_CODE = ENTRIES.to_h { |e| [e.code, e] }.freeze
    end
  end
end
