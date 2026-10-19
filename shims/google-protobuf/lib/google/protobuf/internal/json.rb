# frozen_string_literal: true

require "json"

module Google
  module Protobuf
    module Internal
      # JSON through protostar's encoder and parser, with the gem's options,
      # errors, and extensions of the top-level message written as
      # `"[full.name]": value`.
      module Json # :nodoc: all
        INT64 = %i[int64 sint64 sfixed64 uint64 fixed64].to_h { |t| [t, true] }.freeze

        module_function

        def encode(message, options)
          json = Protostar::JSON.encode(
            message,
            preserve_proto_field_names: options[:preserve_proto_fieldnames] ? true : false,
            emit_defaults: options[:emit_defaults] ? true : false,
            format_enums_as_integers: options[:format_enums_as_integers] ? true : false,
            registry: message.class.__gpool.__registry
          )
          json = with_extensions(message, json, options) unless message.unknown_fields.empty?
          json.force_encoding(Encoding::UTF_8)
        rescue Protostar::JSON::Error, Protostar::Error => e
          raise ParseError, "Error occurred during encoding: #{e.message}"
        end

        def decode(klass, json, options)
          extensions = nil
          if json.include?("\"[")
            tree = ::JSON.parse(json)
            if tree.is_a?(Hash)
              extensions, rest = tree.partition { |k, _| k.start_with?("[") && k.end_with?("]") }
              json = ::JSON.generate(rest.to_h) unless extensions.empty?
            end
          end
          message = Protostar::JSON.decode(
            klass, json,
            ignore_unknown_fields: options[:ignore_unknown_fields] ? true : false,
            registry: klass.__gpool.__registry
          )
          extensions&.each { |key, value| set_extension(klass, message, key[1..-2], value, options) }
          message
        rescue Protostar::JSON::Error, Protostar::Error, ::JSON::ParserError => e
          # upb's wording, which callers match on
          reason = e.message.sub(/\A\S+ has no field "(.*)"\z/) { "No such field: #{$1}" }
          raise ParseError, "Error occurred during parsing: #{reason}"
        end

        def set_extension(klass, message, name, value, options)
          fd = klass.__gpool.lookup(name)
          unless fd.is_a?(FieldDescriptor) && fd.__owner.equal?(klass.descriptor)
            return if options[:ignore_unknown_fields]
            raise ParseError, "Error occurred during parsing: No such field: [#{name}]"
          end
          if fd.repeated?
            list = RepeatedField.__for_field(fd, [])
            value.each { |v| list << from_json(fd, v) }
            fd.set(message, list)
          else
            fd.set(message, from_json(fd, value))
          end
        end

        def from_json(fd, value)
          case fd.type
          when :message, :group then fd.subtype.msgclass.decode_json(::JSON.generate(value))
          when :bytes then value.tr("-_", "+/").unpack1("m")
          when :float, :double then value.is_a?(String) ? Float(value) : value
          when :enum, :string, :bool then value
          else value.is_a?(String) ? Integer(value, 10) : value
          end
        end

        def to_json(fd, value, options)
          case fd.type
          when :message, :group then fd.subtype.msgclass.encode_json(value, options)
          when :bytes then ::JSON.generate([value].pack("m0"))
          when :enum
            options[:format_enums_as_integers] ? fd.subtype.__numbers.fetch(value, value).to_s : ::JSON.generate(value.to_s)
          else
            INT64.key?(fd.type) ? ::JSON.generate(value.to_s) : ::JSON.generate(value)
          end
        end

        def with_extensions(message, json, options)
          pool = message.class.__gpool
          parts = pool.__schema_pool.extensions_of(message.class.descriptor.__schema).filter_map do |ext|
            fd = pool.__wrap(ext)
            values = Extensions.read(message, fd)
            next if values.empty?
            value = fd.repeated? ? "[#{values.map { |v| to_json(fd, v, options) }.join(",")}]" : to_json(fd, values.last, options)
            "#{::JSON.generate("[#{ext.full_name}]")}:#{value}"
          end
          return json if parts.empty?
          (json == "{}") ? "{#{parts.join(",")}}" : "#{json[0..-2]},#{parts.join(",")}}"
        end
      end
    end
  end
end
