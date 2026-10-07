# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # ENUM_FIRST_VALUE_ZERO: An enum whose first value is not zero
      class EnumFirstValueZero < Rule
        REASON = "Readers fall back to the first value of a closed enum and to zero of an open one; both should be the \"unspecified\" value."
        EXPLANATION = <<~TEXT
          proto3 and open enums must start at zero, and protoc enforces it. proto2 enums are closed and may start
          anywhere, but the first value is still the default of every field of that type, so it ends up meaning
          "unset" whether you meant it to or not.

              syntax = "proto2";
              enum Status {
                ACTIVE = 1;
                SUSPENDED = 2;
              }

          Fix: add `STATUS_UNSPECIFIED = 0;` as the first value.
        TEXT

        def check
          context.each(:enum) do |node, enum|
            first = enum.values.first
            next if first.nil? || first.number.zero?
            report(node.value[0], :number, "first value `#{first.name}` of `#{enum.name}` is not zero", label: "not 0",
              help: "add `#{Naming.upper_snake(enum.name)}_UNSPECIFIED = 0;` as the first value")
          end
        end
      end
    end
  end
end
