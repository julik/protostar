# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # RPC_REQUEST_STANDARD_NAME: An rpc whose request is not `<Rpc>Request`
      class RpcRequestStandardName < Rule
        REASON = "A request message of its own per RPC can grow fields without touching any other RPC."
        EXPLANATION = <<~TEXT
          An RPC that takes `User` or `google.protobuf.Empty` cannot add a parameter later without changing that
          shared type for everyone. `GetUserRequest` (or `UserServiceGetUserRequest`) belongs to `GetUser` alone.

              rpc GetUser(UserId) returns (User);

          Fix: `rpc GetUser(GetUserRequest) returns (GetUserResponse);`.
        TEXT

        def check
          context.each(:service) do |service_node, service|
            service.rpcs.each_with_index do |rpc, i|
              base = Naming.pascal(rpc.name)
              wanted = ["#{base}Request", "#{service.name}#{base}Request"]
              next if wanted.include?(rpc.input_type.name)
              report(service_node.rpcs[i], :input_type, "request of `#{rpc.name}` is `#{rpc.input_type.name}`, not `#{wanted[0]}`",
                label: "not `#{wanted[0]}`", help: "take a `#{wanted[0]}` message of its own")
            end
          end
        end
      end
    end
  end
end
