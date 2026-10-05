# frozen_string_literal: true

module Protostar
  # The proto3 JSON mapping, as google-protobuf's Ruby gem implements it.
  #
  #   json = Protostar::JSON.encode(person)                # also person.to_json
  #   Protostar::JSON.decode(Person, json) == person       # also Person.decode_json(json)
  #
  # Well-known types take their special forms. The type inside an Any is
  # looked up by its full name with {Types.find} in the given registry.
  module JSON
    class << self
      # @param message [Message]
      # @param preserve_proto_field_names [Boolean] field names as written in the
      #   .proto rather than their lowerCamel json_name; `preserve_proto_fieldnames`,
      #   google-protobuf's spelling, is accepted too
      # @param emit_defaults [Boolean] also write fields without presence that
      #   hold their default, and empty repeated fields and maps; unset message
      #   fields and oneof members are still left out
      # @param format_enums_as_integers [Boolean] enum numbers instead of names
      # @param registry [Types::Registry] where the types inside Any are found
      # @return [String] compact UTF-8 JSON
      # @raise [EncodeError] for contents with no JSON form, like a Timestamp out of range
      def encode(message, **options)
        Encoder.new(**options).encode(message)
      end

      # @param klass [Class] a message class
      # @param json [String]
      # @param ignore_unknown_fields [Boolean] skip names that are not fields
      #   and enum names that are not values, instead of raising
      # @param registry [Types::Registry] where the types inside Any are found
      # @return [Message]
      # @raise [ParseError] with the path of the offending field
      def decode(klass, json, **options)
        Parser.new(**options).decode(klass, json)
      rescue Protostar::TypeError => e
        raise ParseError, e.message
      end
    end
  end
end

require_relative "json/errors"
require_relative "json/path"
require_relative "json/encoder"
require_relative "json/parser"
