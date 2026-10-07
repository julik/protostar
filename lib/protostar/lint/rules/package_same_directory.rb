# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # PACKAGE_SAME_DIRECTORY: Files in one directory that declare different packages
      class PackageSameDirectory < Rule
        REASON = "One package per directory keeps the package-to-directory mapping one to one."
        EXPLANATION = <<~TEXT
          Two packages in one directory mean the directory says nothing about where a type lives, and many
          generators (Go's in particular) cannot put both in one output package.

              // acme/a.proto
              package acme.a;
              // acme/b.proto
              package acme.b;

          Fix: move one of the files, or give them the same package.
        TEXT

        def check
          dir = directory(context)
          peers = context.all.select { |other| directory(other) == dir }
          packages = peers.map { |other| other.file.package }.uniq
          return if packages.size < 2 || context.file.package == packages.first
          add("files in `#{dir}` declare packages `#{packages.join("`, `")}`",
            [context.span_at(Context::PATHS[:package], label: "differs from `#{packages.first}`")].compact,
            help: "keep one package per directory")
        end

        private

        def directory(context)
          ::File.dirname(context.disk_path || context.name)
        end
      end
    end
  end
end
