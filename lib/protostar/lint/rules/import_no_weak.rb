# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # IMPORT_NO_WEAK: An `import weak`
      class ImportNoWeak < Rule
        REASON = "Weak imports are an internal Google feature that most implementations do not support."
        EXPLANATION = <<~TEXT
          `import weak` lets a file use types from a file that might not be linked in. Only some C++ and Java
          builds honour it, and edition 2024 removed it in favour of `import option`.

              import weak "acme/debug.proto";

          Fix: use a plain import (or `import option` for files that only provide options, from edition 2024).
        TEXT

        def check
          context.ast.weak_dependency.each do |index|
            name = context.ast.dependency[index]
            add("import of `#{name}` is weak", [context.span_at([3, index], label: "weak")].compact,
              help: "use a plain `import`")
          end
        end
      end
    end
  end
end
