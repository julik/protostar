# frozen_string_literal: true

module Protostar
  module Schema
    # Resolved editions features of a descriptor. proto2 and proto3 files are
    # resolved as the editions EDITION_PROTO2 and EDITION_PROTO3, the way protoc
    # does internally, so every descriptor has a complete set.
    #
    # Custom (extension) features such as `pb.cpp` are carried in {#extensions}
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

      # @param edition [Symbol, Integer] an Edition enum name or number
      # @return [Integer]
      def self.edition_number(edition)
        return edition if edition.is_a?(Integer)
        EDITIONS.fetch(edition) { raise Error, "unknown edition #{edition.inspect}" }
      end

      # The defaults for an edition, as protoc computes them from descriptor.proto
      # @param edition [Symbol, Integer]
      # @return [Features]
      def self.defaults(edition)
        number = edition_number(edition)
        values = DEFAULTS.transform_values do |pairs|
          pick = pairs.reverse_each.find { |(ed, _)| EDITIONS.fetch(ed) <= number }
          raise Error, "no feature defaults for edition #{edition.inspect}" unless pick
          pick.last
        end
        new(values, Freezer::EMPTY_HASH)
      end

      # @return [Hash{String => Object}] merged explicit custom features by extension full name
      attr_reader :extensions

      # @api private
      def initialize(values, extensions)
        @values = values.freeze
        @extensions = extensions
        NAMES.each { |name| instance_variable_set(:"@#{name}", values.fetch(name)) }
        freeze
      end

      # @!attribute [r] field_presence
      #   @return [Symbol] :EXPLICIT, :IMPLICIT or :LEGACY_REQUIRED
      # @!attribute [r] enum_type
      #   @return [Symbol] :OPEN or :CLOSED
      # @!attribute [r] repeated_field_encoding
      #   @return [Symbol] :PACKED or :EXPANDED
      # @!attribute [r] utf8_validation
      #   @return [Symbol] :VERIFY or :NONE
      # @!attribute [r] message_encoding
      #   @return [Symbol] :LENGTH_PREFIXED or :DELIMITED
      # @!attribute [r] json_format
      #   @return [Symbol] :ALLOW or :LEGACY_BEST_EFFORT
      # @!attribute [r] enforce_naming_style
      #   @return [Symbol]
      # @!attribute [r] default_symbol_visibility
      #   @return [Symbol]
      # @!attribute [r] enforce_proto_limits
      #   @return [Symbol]
      attr_reader(*NAMES)

      # Overlays a raw `features` option hash (as found in options) on these features
      # @param raw [Hash, nil]
      # @return [Features] self when the overlay changes nothing
      def merge(raw)
        return self if raw.nil? || raw.empty?
        values = @values
        extensions = @extensions
        raw.each do |key, value|
          if key == :__extensions
            extensions = deep_merge(extensions, value)
          elsif key != :__unknown_fields && NAMES.include?(key) && value.is_a?(Symbol)
            values = values.merge(key => value) unless values[key] == value
          end
        end
        return self if values.equal?(@values) && extensions.equal?(@extensions)
        Features.new(values, Ractor.make_shareable(extensions))
      end

      # @return [Hash] the core features, plus `:__extensions` when any are set
      def to_h
        return @values if @extensions.empty?
        @values.merge(__extensions: @extensions)
      end

      def ==(other)
        other.is_a?(Features) && other.to_h == to_h
      end
      alias_method :eql?, :==

      def hash
        to_h.hash
      end

      def inspect
        "#<#{self.class.name} #{to_h.inspect}>"
      end

      private

      def deep_merge(base, overlay)
        return base if overlay.nil? || overlay.empty?
        base.merge(overlay) do |_key, old, new|
          (old.is_a?(Hash) && new.is_a?(Hash)) ? deep_merge(old, new) : new
        end
      end
    end
  end
end
