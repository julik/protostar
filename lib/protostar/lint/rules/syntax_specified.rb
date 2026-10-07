# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # SYNTAX_SPECIFIED: A file without a `syntax` or `edition` line
      class SyntaxSpecified < Rule
        REASON = "Without `syntax` or `edition` a file is proto2, which is rarely what its author meant."
        EXPLANATION = <<~TEXT
          protoc reads a file with neither line as proto2, silently. Fields then need labels, enums are closed, and
          defaults behave differently from proto3; a reader of the file cannot tell which was intended.

              message User {
                optional string name = 1;
              }

          Fix: start the file with `edition = "2023";` (or `syntax = "proto3";`). `--fix` adds
          `syntax = "proto2";`, which spells out what the file already is.
        TEXT

        def check
          return if context.ast.syntax || context.ast.edition
          text = context.text
          fix = unless text.start_with?("\xEF\xBB\xBF".b) || text.b.start_with?("\xEF\xBB\xBF".b)
            Diagnostics::Fix.new("add `syntax = \"proto2\";`, which is what the file already is",
              [Diagnostics::Edit.new(1, 1, 1, 1, "syntax = \"proto2\";\n")])
          end
          span = Diagnostics::Span.new(1, 1, label: "proto2 by default")
          add("file `#{context.name}` has no `syntax` or `edition` line", [span],
            help: "start the file with `edition = \"2023\";` or `syntax = \"proto3\";`", fix: fix)
        end
      end
    end
  end
end
