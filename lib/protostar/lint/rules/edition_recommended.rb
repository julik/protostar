# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # EDITION_RECOMMENDED: A proto2 or proto3 file
      class EditionRecommended < Rule
        REASON = "Editions replace proto2 and proto3; new features (and new defaults) only arrive there."
        EXPLANATION = <<~TEXT
          Editions express what `syntax` used to fix (presence, enum openness, encodings) as features that can be
          set per file, message or field. proto2 and proto3 files keep working, but new behaviour is only added to
          editions. A proto3 file moves to `edition = "2023"` with `option features.field_presence = IMPLICIT;`
          to keep its semantics.

              syntax = "proto3";

          Fix: move to `edition = "2023";`, setting the features that keep the old semantics (see
          https://protobuf.dev/editions/overview/).
        TEXT

        def check
          syntax = context.file.syntax
          return if syntax == :editions
          add("file uses `syntax = \"#{syntax}\"` rather than an edition",
            [context.span_at(Context::PATHS[:syntax], label: syntax.to_s)].compact,
            help: "move to `edition = \"2023\";` with the features that keep #{syntax}'s behaviour")
        end
      end
    end
  end
end
