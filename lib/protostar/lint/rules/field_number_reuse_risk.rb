# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # FIELD_NUMBER_REUSE_RISK: A message with gaps in its field numbers that are not reserved
      class FieldNumberReuseRisk < Rule
        REASON = "A deleted field's number that is not reserved will be reused, and old data will decode as the new field."
        EXPLANATION = <<~TEXT
          When a field is deleted, its number is still in every message written before. If a later field takes the
          number, old data decodes into it as if it were the new field: wrong values, or parse errors when the
          types differ. `reserved` makes protoc refuse the number (and the name) for good.

              message User {
                string name = 1;
                // email was 2
                string phone = 3;
              }

          Fix: `reserved 2; reserved "email";`. If the gap was never used, reserving it costs nothing either.
        TEXT

        def check
          context.each(:message) do |node, message|
            numbers = message.fields.map(&:number)
            next if numbers.empty?
            covered = (numbers.map { |n| n..n } + message.reserved_ranges + message.extension_ranges +
              [19_000..19_999]).sort_by(&:first)
            gaps = []
            next_free = 1
            covered.each do |r|
              break if next_free >= numbers.max
              gaps << (next_free..[r.first - 1, numbers.max - 1].min) if r.first > next_free
              next_free = [next_free, r.last + 1].max
            end
            next if gaps.empty?
            text = gaps.map { |r| (r.size == 1) ? r.first.to_s : "#{r.first} to #{r.last}" }.join(", ")
            report(node, :name, "`#{message.name}` skips field #{(gaps.sum(&:size) == 1) ? "number" : "numbers"} #{text} without reserving them",
              label: "gaps in the numbering", help: "if fields were deleted there, add `reserved #{text};` and reserve their names")
          end
        end
      end
    end
  end
end
