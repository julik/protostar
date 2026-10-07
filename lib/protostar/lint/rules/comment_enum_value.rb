# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # COMMENT_ENUM_VALUE: A enum value without a comment
      class CommentEnumValue < Rule
        REASON = "Enum values are API; the comment above one is its documentation, in the .proto and in generated code."
        EXPLANATION = <<~TEXT
          Comments in a `.proto` are carried into generated code and API documentation. A enum value without one
          leaves every reader to guess what it means and what values it takes. A comment on the line above counts,
          and so does one after the declaration on the same line.

              enum Status {
                STATUS_UNSPECIFIED = 0;
                STATUS_ACTIVE = 1;
              }

          Fix: write what the enum value is for in a `//` comment above it.
        TEXT

        def check
          context.each(:enum_value) do |node, element|
            next if context.comment(node)
            report(node, :name, "enum value `#{element.name}` has no comment", label: "undocumented",
              help: "say what it is for in a `//` comment above it")
          end
        end
      end
    end
  end
end
