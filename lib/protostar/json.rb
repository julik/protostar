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
      # @option options [Boolean] :preserve_proto_field_names field names as written in the
      #   .proto rather than their lowerCamel json_name; `preserve_proto_fieldnames`,
      #   google-protobuf's spelling, is accepted too
      # @option options [Boolean] :emit_defaults also write fields without presence that
      #   hold their default, and empty repeated fields and maps; unset message
      #   fields and oneof members are still left out
      # @option options [Boolean] :format_enums_as_integers enum numbers instead of names
      # @option options [Types::Registry] :registry where the types inside Any are found
      # @return [String] compact UTF-8 JSON
      # @raise [EncodeError] for contents with no JSON form, like a Timestamp out of range
      def encode(message, **options)
        Encoder.new(**options).encode(message)
      end

      # @param klass [Class] a message class
      # @param json [String]
      # @option options [Boolean] :ignore_unknown_fields skip names that are not fields
      #   and enum names that are not values, instead of raising
      # @option options [Types::Registry] :registry where the types inside Any are found
      # @return [Message]
      # @raise [ParseError] with the path of the offending field
      def decode(klass, json, **options)
        Parser.new(**options).decode(klass, json)
      rescue Protostar::TypeError => e
        raise ParseError, e.message
      end

      # Lays compact JSON out as the stdlib generator would with `state`
      # (indent, space, newlines, current depth). Tokens are copied as they
      # are, so numbers keep the spelling the encoder gave them.
      # @param json [String] compact JSON, as {encode} writes it
      # @param state [::JSON::State]
      # @return [String]
      # @api private
      def layout(json, state)
        indent = state.indent
        object_nl = state.object_nl
        array_nl = state.array_nl
        colon = "#{state.space_before}:#{state.space}"
        return json if indent.empty? && object_nl.empty? && array_nl.empty? && colon == ":"
        depth = state.depth
        open = []
        out = +""
        tokens = json.scan(LAYOUT_TOKENS)
        i = 0
        while i < tokens.size
          t = tokens[i]
          case t
          when "{", "["
            close = (t == "{") ? "}" : "]"
            if tokens[i + 1] == close
              out << t << close
              i += 1
            else
              nl = (t == "{") ? object_nl : array_nl
              open << nl
              depth += 1
              out << t << nl << indent * depth
            end
          when "}", "]"
            depth -= 1
            nl = open.pop
            out << nl << indent * depth unless nl.empty?
            out << t
          when "," then out << "," << open.last << indent * depth
          when ":" then out << colon
          else out << t
          end
          i += 1
        end
        out
      end
    end

    LAYOUT_TOKENS = /"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^{}\[\],:"]+/m
  end
end

require_relative "json/errors"
require_relative "json/path"
require_relative "json/encoder"
require_relative "json/parser"
