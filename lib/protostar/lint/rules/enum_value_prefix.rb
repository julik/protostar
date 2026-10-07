# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ENUM_VALUE_PREFIX: An enum value not prefixed with its enum's name
      class EnumValuePrefix < Rule
        REASON = "Enum values are scoped to the enum's parent, not the enum, so unprefixed names clash across enums."
        EXPLANATION = <<~TEXT
          In protobuf (as in C++) enum values are siblings of their enum: `enum Color { RED = 0; }` defines
          `acme.RED`, and a second enum in the package cannot have a `RED`. Prefixing each value with the enum's name
          in UPPER_SNAKE_CASE avoids that for good.

              enum Color {
                UNSPECIFIED = 0;
                RED = 1;
              }

          Fix: `COLOR_UNSPECIFIED = 0; COLOR_RED = 1;`. `--fix` renames a value when nothing else in the file
          mentions it.
        TEXT

        def check
          context.each(:enum) do |node, enum|
            prefix = "#{Naming.upper_snake(enum.name)}_"
            enum.values.each_with_index do |value, i|
              next if value.name.start_with?(prefix)
              wanted = prefix + Naming.upper_snake(value.name)
              span = context.span(node.value[i], :name)
              report(node.value[i], :name, "enum value `#{value.name}` is not prefixed with `#{prefix}`", span: span,
                label: "no `#{prefix}` prefix", help: "name it `#{wanted}`", fix: rename(span, value.name, wanted))
            end
          end
        end
      end
    end
  end
end
