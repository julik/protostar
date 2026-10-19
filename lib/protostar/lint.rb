# frozen_string_literal: true

module Protostar
  # `protostar lint`: compiles `.proto` files, reports the compiler's errors
  # with Diagnostics::Renderer, and checks the files that compiled against
  # best-practice rules, the kind `buf lint` checks, under the same names.
  #
  # ```ruby
  # runner = Protostar::Lint::Runner.new(include_paths: ["proto"], rules: Protostar::Lint.select(["default"]))
  # result = runner.run(["acme/person.proto"])
  # result.diagnostics.each { |d| puts d }
  # ```
  #
  # Each rule is one class under Lint::Rules, in a file named after its id,
  # and one line in RULES.
  module Lint
    autoload :Rule, ::File.expand_path("lint/rule", __dir__)
    autoload :Context, ::File.expand_path("lint/context", __dir__)
    autoload :Naming, ::File.expand_path("lint/naming", __dir__)
    autoload :Config, ::File.expand_path("lint/config", __dir__)
    autoload :Directives, ::File.expand_path("lint/directives", __dir__)
    autoload :Runner, ::File.expand_path("lint/runner", __dir__)
    autoload :Fixer, ::File.expand_path("lint/fixer", __dir__)
    autoload :Command, ::File.expand_path("lint/command", __dir__)

    # Raised for a configuration or command-line mistake
    class Error < Protostar::Error; end

    # The sets a rule can be in, each including the one before
    TIERS = %i[minimal default strict].freeze

    # Every rule: id => [code, the smallest set it is in, its category]
    RULES = {
      "FIELD_NOT_REQUIRED" => ["W0101", :minimal, :longevity],
      "NO_GROUPS" => ["W0102", :minimal, :longevity],
      "ENUM_ZERO_VALUE_SUFFIX" => ["W0103", :minimal, :longevity],
      "ENUM_FIRST_VALUE_ZERO" => ["W0104", :minimal, :longevity],
      "FIELD_NUMBER_REUSE_RISK" => ["W0105", :minimal, :longevity],
      "RESERVED_NAMES_WITH_NUMBERS" => ["W0106", :minimal, :longevity],
      "PACKAGE_DEFINED" => ["W0107", :minimal, :longevity],
      "IMPORT_NO_PUBLIC" => ["W0108", :minimal, :longevity],
      "IMPORT_NO_WEAK" => ["W0109", :minimal, :longevity],
      "IMPORT_USED" => ["W0110", :minimal, :longevity],
      "SYNTAX_SPECIFIED" => ["W0111", :minimal, :longevity],
      "FILE_LOWER_SNAKE_CASE" => ["W0201", :default, :naming],
      "PACKAGE_LOWER_SNAKE_CASE" => ["W0202", :default, :naming],
      "MESSAGE_PASCAL_CASE" => ["W0203", :default, :naming],
      "FIELD_LOWER_SNAKE_CASE" => ["W0204", :default, :naming],
      "ONEOF_LOWER_SNAKE_CASE" => ["W0205", :default, :naming],
      "ENUM_PASCAL_CASE" => ["W0206", :default, :naming],
      # before UPPER_SNAKE_CASE: when both rename a value, the prefixed name fixes both
      "ENUM_VALUE_PREFIX" => ["W0208", :default, :naming],
      "ENUM_VALUE_UPPER_SNAKE_CASE" => ["W0207", :default, :naming],
      "SERVICE_PASCAL_CASE" => ["W0209", :default, :naming],
      "SERVICE_SUFFIX" => ["W0210", :default, :naming],
      "RPC_PASCAL_CASE" => ["W0211", :default, :naming],
      "RPC_REQUEST_STANDARD_NAME" => ["W0212", :default, :naming],
      "RPC_RESPONSE_STANDARD_NAME" => ["W0213", :default, :naming],
      "RPC_REQUEST_RESPONSE_UNIQUE" => ["W0214", :default, :naming],
      "PACKAGE_DIRECTORY_MATCH" => ["W0301", :default, :structure],
      "PACKAGE_SAME_DIRECTORY" => ["W0302", :default, :structure],
      "NO_DEPRECATED_FEATURES" => ["W0303", :default, :structure],
      "PACKAGE_VERSION_SUFFIX" => ["W0304", :strict, :structure],
      "FIELD_NUMBERS_HOT_RANGE" => ["W0305", :strict, :structure],
      "COMMENT_MESSAGE" => ["W0401", :strict, :documentation],
      "COMMENT_FIELD" => ["W0402", :strict, :documentation],
      "COMMENT_ENUM" => ["W0403", :strict, :documentation],
      "COMMENT_ENUM_VALUE" => ["W0404", :strict, :documentation],
      "COMMENT_SERVICE" => ["W0405", :strict, :documentation],
      "COMMENT_RPC" => ["W0406", :strict, :documentation],
      "EDITION_RECOMMENDED" => ["W0501", :strict, :editions]
    }.freeze

    # The rule classes, each loading its file on first use
    module Rules
      RULES.each_key do |id|
        autoload(id.split("_").map(&:capitalize).join.to_sym, ::File.expand_path("lint/rules/#{id.downcase}", __dir__))
      end
    end

    # Returns the category names a rule list can use.
    #: () -> Array[Symbol]
    def self.categories
      RULES.values.map(&:last).uniq
    end

    # - `id`: a rule id
    #
    # Returns its Rule subclass.
    #: (String id) -> singleton(Rule)
    def self.rule_class(id)
      Rules.const_get(id.split("_").map(&:capitalize).join, false)
    end

    # - `id_or_code`: "FIELD_NOT_REQUIRED" or "W0101"
    #
    # Returns the rule id.
    #: (String id_or_code) -> String?
    def self.rule_id(id_or_code)
      key = id_or_code.upcase
      return key if RULES.key?(key)
      RULES.find { |_, (code, _, _)| code == key }&.first
    end

    # The rules a list of set names, category names and rule ids selects, in
    # RULES order
    #
    # - `names`: e.g. ["default", "documentation", "PACKAGE_VERSION_SUFFIX"]
    # - `except`: rule ids or codes to leave out
    #
    # Returns rule ids.
    # Raises Error for a name that is none of these.
    #: (Array[String] names, ?except: Array[String]) -> Array[String]
    def self.select(names, except: [])
      chosen = names.flat_map do |name|
        key = name.to_s.strip
        if TIERS.include?(key.downcase.to_sym)
          upto = TIERS.index(key.downcase.to_sym)
          RULES.select { |_, (_, tier, _)| TIERS.index(tier) <= upto }.keys
        elsif categories.include?(key.downcase.to_sym)
          RULES.select { |_, (_, _, category)| category == key.downcase.to_sym }.keys
        elsif (id = rule_id(key))
          [id]
        else
          raise Error, "Unknown rule or set: #{key} (sets: #{TIERS.join(", ")}; categories: #{categories.join(", ")})"
        end
      end
      skipped = except.map { |name| rule_id(name.to_s.strip) || raise(Error, "Unknown rule: #{name}") }
      RULES.keys & (chosen - skipped)
    end
  end
end
