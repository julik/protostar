# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # COMMENT_MESSAGE: A message without a comment
      class CommentMessage < Rule
        REASON = "Messages are API; the comment above one is its documentation, in the .proto and in generated code."
        EXPLANATION = <<~TEXT
          Comments in a `.proto` are carried into generated code and API documentation. A message without one
          leaves every reader to guess what it means and what values it takes. A comment on the line above counts,
          and so does one after the opening brace.

              message User {
                string id = 1;
              }

          Fix: write what the message is for in a `//` comment above it.
        TEXT

        def check
          context.each(:message) do |node, element|
            next if context.comment(node)
            report(node, :name, "message `#{element.name}` has no comment", label: "undocumented",
              help: "say what it is for in a `//` comment above it")
          end
        end
      end
    end
  end
end
