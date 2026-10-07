# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # COMMENT_ENUM: A enum without a comment
      class CommentEnum < Rule
        REASON = "Enums are API; the comment above one is its documentation, in the .proto and in generated code."
        EXPLANATION = <<~TEXT
          Comments in a `.proto` are carried into generated code and API documentation. A enum without one
          leaves every reader to guess what it means and what values it takes. A comment on the line above counts,
          and so does one after the opening brace.

              enum Status {
                STATUS_UNSPECIFIED = 0;
              }

          Fix: write what the enum is for in a `//` comment above it.
        TEXT

        def check
          context.each(:enum) do |node, element|
            next if context.comment(node)
            report(node, :name, "enum `#{element.name}` has no comment", label: "undocumented",
              help: "say what it is for in a `//` comment above it")
          end
        end
      end
    end
  end
end
