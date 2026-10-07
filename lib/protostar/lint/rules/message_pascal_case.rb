# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # MESSAGE_PASCAL_CASE: A message name that is not PascalCase
      class MessagePascalCase < Rule
        REASON = "Messages become classes; PascalCase is what every style guide and generator expects."
        EXPLANATION = <<~TEXT
          Message names turn into class names in generated code.

              message user_profile {}

          Fix: `message UserProfile {}`, and update the fields and files that refer to it.
        TEXT

        def check
          context.each(:message) do |node, message|
            next if Naming.pascal?(message.name)
            report(node, :name, "message `#{message.name}` is not PascalCase", label: "not PascalCase",
              help: "name it `#{Naming.pascal(message.name)}` and update what refers to it")
          end
        end
      end
    end
  end
end
