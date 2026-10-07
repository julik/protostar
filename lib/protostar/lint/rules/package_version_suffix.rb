# frozen_string_literal: true

module Protostar
  module Lint
    module Rules
      # PACKAGE_VERSION_SUFFIX: A package without a version as its last component
      class PackageVersionSuffix < Rule
        REASON = "A version in the package (`acme.users.v1`) lets a breaking change live next to the old API instead of replacing it."
        EXPLANATION = <<~TEXT
          Once clients depend on a package, breaking changes have to go in a new one. Naming the first `v1` makes
          `v2` the obvious next step. Accepted suffixes: `v1`, `v1beta1`, `v1alpha`, `v1test`, `v1p1beta1` and the
          like.

              package acme.users;

          Fix: `package acme.users.v1;`.
        TEXT

        VERSION = /\Av\d+(?:(?:alpha|beta)\d*|test\w*|p\d+(?:alpha|beta)\d*)?\z/

        def check
          package = context.file.package
          return if package.empty? || package.split(".").last.match?(VERSION)
          add("package `#{package}` has no version suffix",
            [context.span_at(Context::PATHS[:package], label: "no version")].compact,
            help: "add one, e.g. `#{package}.v1`")
        end
      end
    end
  end
end
