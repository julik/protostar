# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # FIELD_NUMBERS_HOT_RANGE: A message using field numbers above 15 while numbers 1 to 15 are free
      class FieldNumbersHotRange < Rule
        REASON = "Field numbers 1 to 15 take one byte on the wire and 16 to 2047 two, so the low ones are best kept for the most common fields."
        EXPLANATION = <<~TEXT
          A field's tag is its number and wire type in a varint: 1 to 15 fit in one byte, 16 to 2047 need two. In a
          message with many fields, the frequently set ones should have the low numbers. This rule only notices
          when 1 to 15 have free numbers or deprecated fields while higher numbers are in use; whether the high
          fields are the frequent ones is a judgement it leaves to you.

              message Event {
                string id = 1;
                string payload = 16;
              }

          Fix: give new frequent fields the free low numbers. Never renumber an existing field: that breaks the
          wire format.
        TEXT

        def check
          context.each(:message) do |node, message|
            high = message.fields.select { |f| f.number > 15 }
            next if high.empty?
            used = message.fields.map(&:number)
            covered = message.reserved_ranges + message.extension_ranges
            free = (1..15).reject { |n| used.include?(n) || covered.any? { |r| r.cover?(n) } }
            stale = message.fields.select { |f| f.number <= 15 && f.options.deprecated? }
            next if free.empty? && stale.empty?
            parts = []
            parts << "#{free.join(", ")} free" unless free.empty?
            parts << "deprecated #{stale.map { |f| "`#{f.name}`" }.join(", ")}" unless stale.empty?
            report(node, :name, "`#{message.name}` uses numbers above 15 with #{parts.join(" and ")} in the one-byte range",
              label: "#{high.size} #{(high.size == 1) ? "field" : "fields"} above 15",
              help: "give new, frequently set fields numbers from 1 to 15; do not renumber existing ones")
          end
        end
      end
    end
  end
end
