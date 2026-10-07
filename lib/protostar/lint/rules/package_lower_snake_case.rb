# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # PACKAGE_LOWER_SNAKE_CASE: A package name that is not lower_snake_case
      class PackageLowerSnakeCase < Rule
        REASON = "Packages become namespaces in every language; lower_snake_case components map cleanly onto all of them."
        EXPLANATION = <<~TEXT
          `package Acme.UserService;` turns into namespaces, modules and directories, some case-sensitive and some
          not.

              package Acme.Users;

          Fix: `package acme.users;`. Every file that names a type with the package has to change too.
        TEXT

        def check
          package = context.file.package
          return if package.empty? || package.split(".").all? { |part| Naming.lower_snake?(part) }
          wanted = package.split(".").map { |part| Naming.lower_snake(part) }.join(".")
          add("package `#{package}` is not lower_snake_case",
            [context.span_at(Context::PATHS[:package], label: "not lower_snake_case")].compact, help: "use `#{wanted}`")
        end
      end
    end
  end
end
