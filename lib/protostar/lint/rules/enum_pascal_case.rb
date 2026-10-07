# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ENUM_PASCAL_CASE: An enum name that is not PascalCase
      class EnumPascalCase < Rule
        REASON = "Enums become types in generated code; PascalCase is what generators expect."
        EXPLANATION = <<~TEXT
              enum order_status { ORDER_STATUS_UNSPECIFIED = 0; }

          Fix: `enum OrderStatus`, and update the fields that refer to it.
        TEXT

        def check
          context.each(:enum) do |node, enum|
            next if Naming.pascal?(enum.name)
            report(node, :name, "enum `#{enum.name}` is not PascalCase", label: "not PascalCase",
              help: "name it `#{Naming.pascal(enum.name)}` and update what refers to it")
          end
        end
      end
    end
  end
end
