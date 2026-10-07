# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # NO_DEPRECATED_FEATURES: A feature or option deprecated in the file's edition
      class NoDeprecatedFeatures < Rule
        REASON = "Deprecated features will be removed in a later edition; the warning says what replaces them."
        EXPLANATION = <<~TEXT
          protoc warns when a file uses a feature or option its edition deprecates, with the replacement in the
          message. With this rule on, that warning is reported once, under this rule.

              edition = "2024";
              option features.(pb.cpp).legacy_closed_enum = true;

          Fix: follow the deprecation message.
        TEXT
        CLAIMS = ["V0507"].freeze

        def check
          context.warnings.each do |warning|
            next unless warning.code == "V0507"
            name, edition, reason = warning.message.match(/\A(.*) has been deprecated in edition (\w+): (.*)\z/m)&.captures
            next unless name
            spans = warning.spans.map { |s| s.primary? ? s.with_label("deprecated") : s }
            add("`#{name}` is deprecated since edition #{edition}", spans, help: reason)
          end
        end
      end
    end
  end
end
