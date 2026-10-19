# frozen_string_literal: true

module Protostar
  module Schema
    # Resolved editions features of a descriptor. proto2 and proto3 files are
    # resolved as the editions EDITION_PROTO2 and EDITION_PROTO3, the way protoc
    # does internally, so every descriptor has a complete set.
    #
    # Custom (extension) features such as `pb.cpp` are carried in #extensions
    # as merged explicit values; their defaults are not known to this model.
    class Features
      # The Edition enum from descriptor.proto (lines 45-82)
      EDITIONS = {
        EDITION_UNKNOWN: 0,
        EDITION_LEGACY: 900,
        EDITION_PROTO2: 998,
        EDITION_PROTO3: 999,
        EDITION_2023: 1000,
        EDITION_2024: 1001,
        EDITION_2026: 1002,
        EDITION_UNSTABLE: 9999,
        EDITION_1_TEST_ONLY: 1,
        EDITION_2_TEST_ONLY: 2,
        EDITION_99997_TEST_ONLY: 99997,
        EDITION_99998_TEST_ONLY: 99998,
        EDITION_99999_TEST_ONLY: 99999,
        EDITION_MAX: 0x7FFFFFFF
      }.freeze

      # Edition numbers to their enum names
      EDITION_NAMES = EDITIONS.invert.freeze

      # The `edition_defaults` annotations on FeatureSet in descriptor.proto,
      # as [edition, value] pairs in ascending edition order. A feature takes the
      # value of the last pair whose edition is at or before the file's edition.
      DEFAULTS = {
        # descriptor.proto lines 1074-1076
        field_presence: [[:EDITION_LEGACY, :EXPLICIT], [:EDITION_PROTO3, :IMPLICIT], [:EDITION_2023, :EXPLICIT]],
        # lines 1091-1092
        enum_type: [[:EDITION_LEGACY, :CLOSED], [:EDITION_PROTO3, :OPEN]],
        # lines 1107-1108
        repeated_field_encoding: [[:EDITION_LEGACY, :EXPANDED], [:EDITION_PROTO3, :PACKED]],
        # lines 1124-1125
        utf8_validation: [[:EDITION_LEGACY, :NONE], [:EDITION_PROTO3, :VERIFY]],
        # line 1140
        message_encoding: [[:EDITION_LEGACY, :LENGTH_PREFIXED]],
        # lines 1156-1157
        json_format: [[:EDITION_LEGACY, :LEGACY_BEST_EFFORT], [:EDITION_PROTO3, :ALLOW]],
        # lines 1180-1182
        enforce_naming_style: [[:EDITION_LEGACY, :STYLE_LEGACY], [:EDITION_2024, :STYLE2024], [:EDITION_2026, :STYLE2026]],
        # lines 1212-1214
        default_symbol_visibility: [[:EDITION_LEGACY, :EXPORT_ALL], [:EDITION_2024, :EXPORT_TOP_LEVEL], [:EDITION_2026, :STRICT]],
        # lines 1241-1245
        enforce_proto_limits: [[:EDITION_LEGACY, :LEGACY_NO_EXPLICIT_LIMITS], [:EDITION_2026, :PROTO_LIMITS2026]]
      }.transform_values { |pairs| pairs.map(&:freeze).freeze }.freeze

      # Names of the core features, in FeatureSet field number order
      NAMES = DEFAULTS.keys.freeze

      # - `edition`: an Edition enum name or number
      #: ((Symbol | Integer) edition) -> Integer
      def self.edition_number(edition)
        return edition if edition.is_a?(Integer)
        EDITIONS.fetch(edition) { raise Error, "unknown edition #{edition.inspect}" }
      end

      # The defaults for an edition, as protoc computes them from descriptor.proto
      #: ((Symbol | Integer) edition) -> Features
      def self.defaults(edition)
        number = edition_number(edition)
        values = DEFAULTS.transform_values do |pairs|
          pick = pairs.reverse_each.find { |(ed, _)| EDITIONS.fetch(ed) <= number }
          raise Error, "no feature defaults for edition #{edition.inspect}" unless pick
          pick.last
        end
        new(values, Freezer::EMPTY_HASH)
      end

      # Merged explicit custom features by extension.
      attr_reader :extensions #: Hash[Field, MessageValue]

      def initialize(values, extensions) # :nodoc:
        @values = values.freeze
        @extensions = extensions
        NAMES.each { |name| instance_variable_set(:"@#{name}", values.fetch(name)) }
        @hash = [@values, @extensions].hash
        freeze
      end

      # :EXPLICIT, :IMPLICIT or :LEGACY_REQUIRED
      attr_reader :field_presence #: Symbol
      # :OPEN or :CLOSED
      attr_reader :enum_type #: Symbol
      # :PACKED or :EXPANDED
      attr_reader :repeated_field_encoding #: Symbol
      # :VERIFY or :NONE
      attr_reader :utf8_validation #: Symbol
      # :LENGTH_PREFIXED or :DELIMITED
      attr_reader :message_encoding #: Symbol
      # :ALLOW or :LEGACY_BEST_EFFORT
      attr_reader :json_format #: Symbol
      attr_reader :enforce_naming_style, :default_symbol_visibility, :enforce_proto_limits #: Symbol

      # Overlays a declared `features` option (a FeatureSet) on these features
      #
      # Returns self when the overlay changes nothing.
      #: (MessageValue? declared) -> Features
      def merge(declared)
        return self if declared.nil? || declared.empty?
        values = @values
        declared.fields.each do |key, value|
          next unless NAMES.include?(key) && value.is_a?(Symbol)
          values = values.merge(key => value) unless values[key] == value
        end
        extensions = MessageValue.merge_values(@extensions, declared.extensions)
        return self if values.equal?(@values) && extensions.equal?(@extensions)
        Features.new(values, extensions)
      end

      # - `values`: core features to override
      #
      # Returns self when nothing changes.
      #: (**untyped values) -> Features
      def with(**values)
        return self if values.all? { |k, v| @values[k] == v }
        Features.new(@values.merge(values), @extensions)
      end

      # Returns the core features by name.
      #: () -> Hash[Symbol, Symbol]
      def to_h
        @values
      end

      def ==(other)
        other.is_a?(Features) && other.to_h == @values && other.extensions == @extensions
      end
      alias_method :eql?, :==

      attr_reader :hash

      def inspect
        custom = @extensions.map { |f, v| " (#{f.full_name}): #{v.inspect}" }.join
        "#<#{self.class.name} #{@values.inspect}#{custom}>"
      end
    end
  end
end
