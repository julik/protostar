# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # IMPORT_NO_PUBLIC: An `import public`
      class ImportNoPublic < Rule
        REASON = "`import public` makes a file re-export another's types, which hides real dependencies and makes moving types hard."
        EXPLANATION = <<~TEXT
          `import public "b.proto";` in a.proto lets every file that imports a.proto use b.proto's types without
          importing it. It exists for moving types between files; as a habit it hides who depends on what, and not
          every language supports it.

              import public "acme/common.proto";

          Fix: import the file directly wherever its types are used.
        TEXT

        def check
          context.ast.public_dependency.each do |index|
            name = context.ast.dependency[index]
            add("import of `#{name}` is public", [context.span_at([3, index], label: "re-exports `#{name}`")].compact,
              help: "import `#{name}` directly in the files that use it")
          end
        end
      end
    end
  end
end
