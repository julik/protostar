# frozen_string_literal: true

module Protostar
  # The descriptor model: an immutable, Ractor-shareable graph of files,
  # messages, fields, enums and services, built from a descriptor hash shaped
  # like `FileDescriptorProto#to_h` and turned back into one with `#to_h`.
  module Schema
    # Raised for malformed descriptor hashes, missing dependencies and pool clashes
    class Error < Protostar::Error; end

    # The JSON name protoc derives from a field name: underscores dropped,
    # the letter after each one upper-cased
    # @param name [String]
    # @return [String]
    def self.json_name(name)
      out = +""
      upper = false
      name.each_char do |c|
        if c == "_"
          upper = true
        elsif upper
          out << c.upcase(:ascii)
          upper = false
        else
          out << c
        end
      end
      out
    end

    # Raised when a type name, extendee or method type cannot be resolved
    class ResolveError < Error
      # @return [String, nil] the name as written
      attr_reader :name
      # @return [String, nil] the scope the lookup started from
      attr_reader :scope

      def initialize(message, name: nil, scope: nil)
        @name = name
        @scope = scope
        super(message)
      end
    end
  end
end

require_relative "schema/freezer"
require_relative "schema/options"
require_relative "schema/features"
require_relative "schema/source_info"
require_relative "schema/descriptor"
require_relative "schema/file"
require_relative "schema/message"
require_relative "schema/extension_range"
require_relative "schema/oneof"
require_relative "schema/field"
require_relative "schema/enum"
require_relative "schema/service"
require_relative "schema/resolver"
require_relative "schema/pool"
require_relative "schema/default_value"
require_relative "schema/draft"
require_relative "schema/builder"
