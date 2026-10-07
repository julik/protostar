# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # COMMENT_FIELD: A field without a comment
      class CommentField < Rule
        REASON = "Fields are API; the comment above one is its documentation, in the .proto and in generated code."
        EXPLANATION = <<~TEXT
          Comments in a `.proto` are carried into generated code and API documentation. A field without one
          leaves every reader to guess what it means and what values it takes. A comment on the line above counts,
          and so does one after the declaration on the same line.

              message User {
                // Stable across renames; never reused.
                string id = 1;
                string name = 2;
              }

          Fix: write what the field is for in a `//` comment above it.
        TEXT

        def check
          context.each(:field) do |node, element|
            next if context.comment(node)
            report(node, :name, "field `#{element.name}` has no comment", label: "undocumented",
              help: "say what it is for in a `//` comment above it")
          end
        end
      end
    end
  end
end
