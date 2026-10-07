# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # IMPORT_USED: An import nothing in the file uses
      class ImportUsed < Rule
        REASON = "An unused import is a dependency in the build graph that does nothing but slow it down and mislead readers."
        EXPLANATION = <<~TEXT
          protoc warns about these too; with this rule on, the warning is reported once, under this rule. An
          import is used when a type, extension or option from it (or from what it imports publicly) is named in
          the file.

              import "google/protobuf/timestamp.proto";
              message A { string id = 1; }

          Fix: remove the import.
        TEXT
        CLAIMS = ["V0703"].freeze

        def check
          context.warnings.each do |warning|
            next unless warning.code == "V0703"
            name = warning.message[/\AImport (.*) is unused\.\z/, 1]
            spans = warning.spans.map { |s| s.primary? ? s.with_label("unused") : s }
            spans = [Diagnostics::Span.new(warning.line, warning.column, label: "unused")] if spans.empty? && warning.line
            add("import `#{name}` is unused", spans, help: "remove the import")
          end
        end
      end
    end
  end
end
