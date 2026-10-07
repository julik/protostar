# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # SERVICE_SUFFIX: A service whose name does not end in `Service`
      class ServiceSuffix < Rule
        REASON = "A `Service` suffix keeps the generated client and server names from colliding with message names."
        EXPLANATION = <<~TEXT
          Generators name stubs and base classes after the service; `service User` next to `message User` makes
          those collide or read ambiguously.

              service Users { rpc Get(GetRequest) returns (GetResponse); }

          Fix: `service UsersService`.
        TEXT

        def check
          context.each(:service) do |node, service|
            next if service.name.end_with?("Service")
            report(node, :name, "service `#{service.name}` does not end in `Service`", label: "no `Service` suffix",
              help: "name it `#{service.name}Service`")
          end
        end
      end
    end
  end
end
