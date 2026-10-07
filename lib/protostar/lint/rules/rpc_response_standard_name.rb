# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # RPC_RESPONSE_STANDARD_NAME: An rpc whose response is not `<Rpc>Response`
      class RpcResponseStandardName < Rule
        REASON = "A response message of its own per RPC can grow fields without touching any other RPC."
        EXPLANATION = <<~TEXT
          Returning a shared type such as `User` means a field added for one RPC shows up in all of them.

              rpc GetUser(GetUserRequest) returns (User);

          Fix: `returns (GetUserResponse)`, with a `User user = 1;` field in it.
        TEXT

        def check
          context.each(:service) do |service_node, service|
            service.rpcs.each_with_index do |rpc, i|
              base = Naming.pascal(rpc.name)
              wanted = ["#{base}Response", "#{service.name}#{base}Response"]
              next if wanted.include?(rpc.output_type.name)
              report(service_node.rpcs[i], :output_type, "response of `#{rpc.name}` is `#{rpc.output_type.name}`, not `#{wanted[0]}`",
                label: "not `#{wanted[0]}`", help: "return a `#{wanted[0]}` message of its own")
            end
          end
        end
      end
    end
  end
end
