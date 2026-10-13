# frozen_string_literal: true

require_relative "lib/protostar/version"

Gem::Specification.new do |spec|
  spec.name = "protostar"
  spec.version = Protostar::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]

  spec.summary = "(Slightly unhinged) pure Ruby protobufs"
  spec.description = "Compiles .proto files to Ruby, encodes and decodes protobuf messages, and can stand in for the google-protobuf gem. No protoc, no native extensions."
  spec.homepage = "https://github.com/julik/protostar"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The shim's lib/ stays off require_paths: protostar/google_protobuf_shim puts it on
  spec.files = Dir["lib/**/*.rb", "lib/protostar/compiler/include/**/*", "sig/**/*.rbs", "exe/*", "LICENSE.txt",
    "shims/google-protobuf/lib/**/*.rb",
    "THIRD_PARTY_NOTICES.md", "README.md",
    "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = Dir["exe/*"].map { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-fail-fast"
  spec.add_development_dependency "standard", "~> 1.50"
  spec.add_development_dependency "magic_frozen_string_literal"
  spec.add_development_dependency "yard"
  spec.add_development_dependency "rbs", ">= 3.5"
end
