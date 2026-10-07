# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # COMMENT_RPC: A rpc without a comment
      class CommentRpc < Rule
        REASON = "RPCs are API; the comment above one is its documentation, in the .proto and in generated code."
        EXPLANATION = <<~TEXT
          Comments in a `.proto` are carried into generated code and API documentation. A rpc without one
          leaves every reader to guess what it means and what values it takes. A comment on the line above counts,
          and so does one after the opening brace.

              service UserService {
                rpc GetUser(GetUserRequest) returns (GetUserResponse);
              }

          Fix: write what the rpc is for in a `//` comment above it.
        TEXT

        def check
          context.each(:method) do |node, element|
            next if context.comment(node)
            report(node, :name, "rpc `#{element.name}` has no comment", label: "undocumented",
              help: "say what it is for in a `//` comment above it")
          end
        end
      end
    end
  end
end
