# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # FIELD_LOWER_SNAKE_CASE: A field name that is not lower_snake_case
      class FieldLowerSnakeCase < Rule
        REASON = "Generators derive accessors and JSON names from field names on the assumption they are lower_snake_case."
        EXPLANATION = <<~TEXT
          The JSON name of `foo_bar` is `fooBar`, and generated accessors camelCase or PascalCase it as each
          language wants. A field called `fooBar` or `FooBar` makes those conversions guess, and two such fields can
          end up with the same JSON name.

              message User {
                string firstName = 1;
              }

          Fix: `string first_name = 1;`. Renaming is wire-compatible but changes generated accessors. `--fix`
          renames the field when nothing else in the file mentions it.
        TEXT

        def check
          context.each(:field) do |node, field|
            next if node.type == :TYPE_GROUP || Naming.lower_snake?(field.name)
            wanted = Naming.lower_snake(field.name)
            span = context.span(node, :name)
            report(node, :name, "field `#{field.name}` is not lower_snake_case", span: span, label: "not lower_snake_case",
              help: "name it `#{wanted}`", fix: rename(span, field.name, wanted))
          end
        end
      end
    end
  end
end
