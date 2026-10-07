# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # SERVICE_PASCAL_CASE: A service name that is not PascalCase
      class ServicePascalCase < Rule
        REASON = "Services become classes and interfaces in generated code; PascalCase is what generators expect."
        EXPLANATION = <<~TEXT
              service user_api {}

          Fix: `service UserAPIService {}`.
        TEXT

        def check
          context.each(:service) do |node, service|
            next if Naming.pascal?(service.name)
            report(node, :name, "service `#{service.name}` is not PascalCase", label: "not PascalCase",
              help: "name it `#{Naming.pascal(service.name)}`")
          end
        end
      end
    end
  end
end
