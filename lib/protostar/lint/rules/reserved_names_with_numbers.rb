# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # RESERVED_NAMES_WITH_NUMBERS: A message or enum that reserves numbers but no names, or names but no numbers
      class ReservedNamesWithNumbers < Rule
        REASON = "A deleted field needs both its number and its name reserved: the number for the binary format, the name for JSON and text."
        EXPLANATION = <<~TEXT
          The binary format identifies a field by number, JSON and the text format by name. Reserving only the
          number lets a new field take the old name, and old JSON then fills it; reserving only the name lets a new
          field take the number, and old binary data fills it.

              message User {
                reserved 2;
                string name = 1;
              }

          Fix: reserve both, `reserved 2; reserved "email";` (`reserved email;` in editions).
        TEXT

        def check
          context.each(:message) { |node, message| check_element(node, message, "fields", 9, 10) }
          context.each(:enum) { |node, enum| check_element(node, enum, "values", 4, 5) }
        end

        private

        def check_element(node, element, what, range_field, name_field)
          numbers = node.reserved_range
          names = node.reserved_name
          if !numbers.empty? && names.empty?
            report(numbers[0], :number, "`#{element.name}` reserves #{what} by number but not by name",
              label: "number only", help: "reserve the deleted #{what}' names too")
          elsif numbers.empty? && !names.empty?
            report(node, :name, "`#{element.name}` reserves #{what} by name but not by number",
              span: context.span_at(node.path + [name_field]), label: "name only",
              help: "reserve the deleted #{what}' numbers too")
          end
        end
      end
    end
  end
end
