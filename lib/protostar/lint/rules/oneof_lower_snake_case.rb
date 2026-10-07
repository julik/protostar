# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ONEOF_LOWER_SNAKE_CASE: A oneof name that is not lower_snake_case
      class OneofLowerSnakeCase < Rule
        REASON = "Oneof names become accessors and enum cases in generated code, derived on the assumption they are lower_snake_case."
        EXPLANATION = <<~TEXT
              oneof PaymentMethod { string card = 1; string iban = 2; }

          Fix: `oneof payment_method { ... }`. `--fix` renames it when nothing else in the file mentions it.
        TEXT

        def check
          context.each(:oneof) do |node, oneof|
            next if Naming.lower_snake?(oneof.name)
            wanted = Naming.lower_snake(oneof.name)
            span = context.span(node, :name)
            report(node, :name, "oneof `#{oneof.name}` is not lower_snake_case", span: span, label: "not lower_snake_case",
              help: "name it `#{wanted}`", fix: rename(span, oneof.name, wanted))
          end
        end
      end
    end
  end
end
