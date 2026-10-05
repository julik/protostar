# frozen_string_literal: true

# Helpers for the compiler tests
module CompilerSupport
  # The corpus files with goldens, as the names protoc compiled them under
  def self.goldens
    Dir[File.join(Corpus::GOLDENS, "**", "*.json")].sort.map do |path|
      path.delete_prefix(Corpus::GOLDENS + "/").delete_suffix(".json")
    end
  end

  # protoc's warnings for the corpus: only the deprecation of generic services
  GENERIC_SERVICES_WARNING = "warning: Generic services (cc_generic_services, java_generic_services, and " \
    "py_generic_services) are deprecated in favor of using plugins that generate code specific to your particular " \
    "RPC system. Additional code generator options may be required to enable generic services and total removal of " \
    "these options is planned in future breaking releases."
  CORPUS_WARNINGS = %w[
    google/protobuf/edition_unittest.proto google/protobuf/unittest.proto
    google/protobuf/unittest_custom_options.proto google/protobuf/unittest_lazy_dependencies.proto
    google/protobuf/unittest_lazy_dependencies_custom_option.proto google/protobuf/unittest_lazy_dependencies_enum.proto
  ].to_h { |name| [name, ["#{name}: #{GENERIC_SERVICES_WARNING}"]] }.freeze

  def self.compiler
    Protostar::Compiler.new(include_paths: Corpus::INCLUDE_ROOTS)
  end

  # A descriptor hash without the `:__extensions` and `:__unknown_fields`
  # keys, which protoc's JSON (and so the goldens) cannot carry
  def self.strip_extensions(value)
    case value
    when Hash
      value.each_with_object({}) do |(k, v), out|
        out[k] = strip_extensions(v) unless k == :__extensions || k == :__unknown_fields
      end
    when Array then value.map { |v| strip_extensions(v) }
    else value
    end
  end

  # Diagnostics formatted the way protoc's parser tests print them: 0-based
  # `line:column: message`, `-1:0:` where there is no position
  def self.zero_based(diagnostics)
    diagnostics.map do |d|
      position = d.line ? "#{d.line - 1}:#{d.column - 1}" : "-1:0"
      "#{position}: #{d.message}\n"
    end.join
  end
end
