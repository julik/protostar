# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # PACKAGE_DIRECTORY_MATCH: A file whose directory does not match its package
      class PackageDirectoryMatch < Rule
        REASON = "When `acme.users.v1` lives in `acme/users/v1/`, a type's file can be found from its name, by people and by tools."
        EXPLANATION = <<~TEXT
          Import paths and packages are separate namespaces; keeping them aligned is what lets you find
          `acme.users.v1.User` in `acme/users/v1/`. The check looks at where the file is on disk, so it does not
          depend on the include path.

              // proto/users.proto
              package acme.users.v1;

          Fix: move the file to `proto/acme/users/v1/users.proto` (the include path being `proto`).
        TEXT

        def check
          package = context.file.package
          return if package.empty?
          wanted = package.tr(".", "/")
          dir = ::File.dirname(context.disk_path || context.name)
          return if dir == wanted || dir.end_with?("/#{wanted}")
          add("package `#{package}` is not in a `#{wanted}` directory",
            [context.span_at(Context::PATHS[:package], label: "expects `#{wanted}/`")].compact,
            help: "move the file into a `#{wanted}/` directory")
        end
      end
    end
  end
end
