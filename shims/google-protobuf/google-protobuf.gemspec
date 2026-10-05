# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "google-protobuf"
  # 4.36.2 is the upstream API this mirrors; the fourth part is ours
  spec.version = "4.36.2.1"
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]

  spec.summary = "The google-protobuf Ruby API on top of protostar, in pure Ruby"
  spec.description = "Stands in for Google's google-protobuf gem (for grpc and anything else that depends on it) " \
    "with protostar underneath. No native extension, no FFI."
  spec.homepage = "https://github.com/julik/protostar"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/shims/google-protobuf"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "known_differences.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "protostar"
end
