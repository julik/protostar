# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # PACKAGE_DEFINED: A file without a `package`
      class PackageDefined < Rule
        REASON = "A file without a package puts every type it declares in the global namespace, where any other file can clash with it."
        EXPLANATION = <<~TEXT
          Type names are global within a program. Without a package, `message User` is just `User`, and the first
          other schema with a `User` breaks the build, or worse, the link.

              syntax = "proto3";
              message User {}

          Fix: add `package acme.users.v1;` after the syntax line, matching the file's directory.
        TEXT

        def check
          return unless context.file.package.empty?
          span = context.span_at(Context::PATHS[:syntax]) || context.span_at(Context::PATHS[:edition])
          add("file `#{context.name}` has no package", span ? [span.with_label("no `package` follows")] : [],
            help: "add a `package` statement, e.g. `package acme.v1;`")
        end
      end
    end
  end
end
