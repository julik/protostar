# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # RPC_REQUEST_RESPONSE_UNIQUE: A message used as the request or response of more than one rpc
      class RpcRequestResponseUnique < Rule
        REASON = "Requests and responses shared between RPCs will need to diverge, and then cannot."
        EXPLANATION = <<~TEXT
          Two RPCs that take the same request are tied together: a field one of them needs appears in the other's
          API too. The same goes for responses, and for a message used as one RPC's request and another's response.

              rpc GetUser(UserRequest) returns (User);
              rpc DeleteUser(UserRequest) returns (User);

          Fix: give each RPC its own `<Rpc>Request` and `<Rpc>Response`.
        TEXT

        def check
          first = {}
          context.each(:service) do |service_node, service|
            service.rpcs.each_with_index do |rpc, i|
              node = service_node.rpcs[i]
              [[rpc.input_type, :input_type, "request"], [rpc.output_type, :output_type, "response"]].each do |type, kind, role|
                if (earlier = first[type.full_name])
                  other_node, other_kind, other_rpc, other_role = earlier
                  report(node, kind, "`#{type.name}` is the #{role} of `#{rpc.name}` and already the #{other_role} of `#{other_rpc}`",
                    label: "used again", related: [[other_node, other_kind, "first used here"]],
                    help: "give `#{rpc.name}` a `#{Naming.pascal(rpc.name)}#{role.capitalize}` of its own")
                else
                  first[type.full_name] = [node, kind, rpc.name, role]
                end
              end
            end
          end
        end
      end
    end
  end
end
