# frozen_string_literal: true

module Protostar
  # The descriptor model: an immutable, Ractor-shareable graph of files,
  # messages, fields, enums and services. File.draft builds one;
  # File#to_proto and File.from_proto translate to and from protoc's
  # `FileDescriptorProto`.
  module Schema
    autoload :DefaultValue, ::File.expand_path("schema/default_value", __dir__)
    autoload :Draft, ::File.expand_path("schema/draft", __dir__)
    autoload :ExtensionRange, ::File.expand_path("schema/extension_range", __dir__)
    autoload :Proto, ::File.expand_path("schema/proto", __dir__)
    autoload :Resolver, ::File.expand_path("schema/resolver", __dir__)
    autoload :SourceInfo, ::File.expand_path("schema/source_info", __dir__)

    # Raised for malformed descriptors, missing dependencies and pool clashes
    class Error < Protostar::Error; end

    # The JSON name protoc derives from a field name: underscores dropped,
    # the letter after each one upper-cased
    #: (String name) -> String
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
      # The name as written.
      attr_reader :name #: String?
      # The scope the lookup started from.
      attr_reader :scope #: String?

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
require_relative "schema/descriptor"
require_relative "schema/file"
require_relative "schema/message"
require_relative "schema/oneof"
require_relative "schema/field"
require_relative "schema/enum"
require_relative "schema/service"
require_relative "schema/pool"
