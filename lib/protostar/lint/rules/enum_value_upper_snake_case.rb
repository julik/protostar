# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ENUM_VALUE_UPPER_SNAKE_CASE: An enum value name that is not UPPER_SNAKE_CASE
      class EnumValueUpperSnakeCase < Rule
        REASON = "Enum values become constants; UPPER_SNAKE_CASE is the convention in every generator."
        EXPLANATION = <<~TEXT
              enum Color { color_unspecified = 0; colorRed = 1; }

          Fix: `COLOR_UNSPECIFIED`, `COLOR_RED`. Renaming is wire-compatible but changes the JSON and text names.
          `--fix` renames a value when nothing else in the file mentions it.
        TEXT

        def check
          context.each(:enum_value) do |node, value|
            next if Naming.upper_snake?(value.name)
            wanted = Naming.upper_snake(value.name)
            span = context.span(node, :name)
            report(node, :name, "enum value `#{value.name}` is not UPPER_SNAKE_CASE", span: span,
              label: "not UPPER_SNAKE_CASE", help: "name it `#{wanted}`", fix: rename(span, value.name, wanted))
          end
        end
      end
    end
  end
end
