# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # NO_GROUPS: A proto2 `group` field
      class NoGroups < Rule
        REASON = "Groups are a proto2 relic most languages' tooling handles badly; a message field says the same thing."
        EXPLANATION = <<~TEXT
          A group declares a nested message and a field of that type at once, encoded with start and end tags
          instead of a length. Most code generators and JSON mappings treat them as an oddity, proto3 does not
          have them, and editions only keep the encoding (`features.message_encoding = DELIMITED`).

              message SearchResponse {
                repeated group Result = 1 {
                  optional string url = 2;
                }
              }

          Fix: in a new schema, declare `message Result` and a `repeated Result result = 1;` field. For data already
          written, switching changes the wire format; move the file to editions and keep the field DELIMITED.
        TEXT

        def check
          context.each(:field) do |node, field|
            next unless node.type == :TYPE_GROUP
            report(node, :type, "field `#{field.name}` is a group", label: "group",
              help: "declare `message #{field.message_type.name}` and a field of that type")
          end
        end
      end
    end
  end
end
