# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # RPC_PASCAL_CASE: An rpc name that is not PascalCase
      class RpcPascalCase < Rule
        REASON = "RPCs become methods in every language's stubs, converted from PascalCase."
        EXPLANATION = <<~TEXT
              rpc get_user(GetUserRequest) returns (GetUserResponse);

          Fix: `rpc GetUser(...)`.
        TEXT

        def check
          context.each(:method) do |node, rpc|
            next if Naming.pascal?(rpc.name)
            report(node, :name, "rpc `#{rpc.name}` is not PascalCase", label: "not PascalCase",
              help: "name it `#{Naming.pascal(rpc.name)}`")
          end
        end
      end
    end
  end
end
