# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # FIELD_NOT_REQUIRED: A proto2 `required` field, or an editions field with `LEGACY_REQUIRED` presence
      class FieldNotRequired < Rule
        REASON = "A required field can never be removed or made optional without breaking every reader that still checks it."
        EXPLANATION = <<~TEXT
          `required` looks like validation, but it is a promise about every message that will ever be written. A
          reader built from the schema rejects a message without the field, so the field can never be removed, and
          making it `optional` breaks every old reader that meets a message without it. Google's own style guide
          calls required fields harmful, and proto3 dropped them.

              syntax = "proto2";
              message Order {
                required string id = 1;
              }

          Fix: make the field `optional` and check that it is set where the message is used. In editions, drop
          `features.field_presence = LEGACY_REQUIRED`.
        TEXT

        def check
          context.each(:field) do |node, field|
            next unless field.required?
            if node.label == :LABEL_REQUIRED
              report(node, :name, "field `#{field.name}` is required", span: context.span_at(node.path + [4]),
                label: "required forever", help: "make it `optional` and check that it is set in code")
            else
              report(node, :name, "field `#{field.name}` has LEGACY_REQUIRED presence", label: "required forever",
                help: "remove `features.field_presence = LEGACY_REQUIRED` and check that it is set in code")
            end
          end
        end
      end
    end
  end
end
