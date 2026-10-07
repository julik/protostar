# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ENUM_ZERO_VALUE_SUFFIX: An enum whose zero value does not end in `_UNSPECIFIED`
      class EnumZeroValueSuffix < Rule
        REASON = "The zero value is what every reader sees for an unset or unknown enum, so it should mean \"unspecified\"."
        EXPLANATION = <<~TEXT
          A field that was never set reads as the enum's zero value, and so does, in proto3 and open enums, a number
          the reader does not know. If zero is a real choice (`RED`), there is no way to tell "red" from "nobody
          said". Naming it `COLOR_UNSPECIFIED` keeps zero free to mean exactly that.

              enum Color {
                RED = 0;
                GREEN = 1;
              }

          Fix: add `COLOR_UNSPECIFIED = 0;` and renumber, in a new enum; in a released one, rename the zero value
          to `COLOR_UNSPECIFIED` (the wire format does not change, the JSON and text names do). `--fix` renames it
          when nothing else in the file mentions the old name.
        TEXT

        def check
          context.each(:enum) do |node, enum|
            index = enum.values.index { |v| v.number.zero? }
            next unless index
            value = enum.values[index]
            next if value.name.end_with?("_UNSPECIFIED")
            wanted = "#{Naming.upper_snake(enum.name)}_UNSPECIFIED"
            value_node = node.value[index]
            span = context.span(value_node, :name)
            report(value_node, :name, "zero value `#{value.name}` of `#{enum.name}` does not end in `_UNSPECIFIED`",
              span: span, label: "read for every unset field", help: "name it `#{wanted}`",
              fix: rename(span, value.name, wanted))
          end
        end
      end
    end
  end
end
