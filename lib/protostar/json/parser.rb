# frozen_string_literal: true

require "json"

module Protostar
  module JSON
    # Reads proto3 JSON into a message, accepting what google-protobuf's Ruby
    # gem accepts. The stdlib parser builds the raw tree; this walks it
    # against the message's fields.
    # @api private
    class Parser
      F = Message::FieldInfo
      SPECIAL = Encoder::SPECIAL

      # Marks an enum name that is not known, dropped with ignore_unknown_fields
      SKIP = Object.new.freeze

      RANGES = Message::Coercion::RANGES
      INT64_LIMIT = 2.0**63
      UINT64_LIMIT = 2.0**64
      QUOTED_INTEGER = /\A-?\d+\z/
      # Integers in decimal or exponent form, read through a double as protoc does ("1e5")
      QUOTED_INTEGRAL = /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
      QUOTED_FLOAT = /\A\s*[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
      NONFINITE = {"NaN" => Float::NAN, "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY}.freeze
      BASE64 = %r{\A[A-Za-z0-9+/\-_]*={0,2}\z}
      TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:(Z)|([+-])(\d{2}):(\d{2}))\z/
      DURATION = /\A(-)?(\d*)(?:\.(\d*))?s\z/
      # A string literal, or -0 standing alone as a number
      NEGATIVE_ZERO = /"(?:[^"\\]|\\.)*"|(?<![\w.])-0(?![\w.])/m
      VALUE = "google.protobuf.Value"
      NULL_VALUE = Encoder::NULL_VALUE

      # @param ignore_unknown_fields [Boolean] skip unknown field names and enum names
      # @param registry [Types::Registry] where the types inside Any are looked up
      def initialize(ignore_unknown_fields: false, registry: nil)
        @ignore_unknown = ignore_unknown_fields
        @registry = registry
        @path = []
      end

      # @param klass [Class] a message class
      # @param string [String] JSON
      # @return [Message]
      # @raise [ParseError]
      def decode(klass, string)
        tree = begin
          # the stdlib reads -0 as the Integer 0, losing the sign a double field keeps
          string = string.gsub(NEGATIVE_ZERO) { |m| (m == "-0") ? "-0.0" : m } if string.include?("-0")
          ::JSON.parse(string, allow_duplicate_key: false, allow_comments: false, allow_nan: false)
        rescue ::JSON::ParserError, EncodingError, ArgumentError => e
          raise ParseError, "invalid JSON: #{e.message}"
        end
        if tree.nil? && klass.descriptor.full_name != VALUE
          raise ParseError, "expected a JSON object for #{klass.descriptor.full_name}, got null"
        end
        message(klass, tree)
      end

      private

      def fail!(message)
        raise ParseError.new(message, Path.to_s(@path))
      end

      def describe(node)
        case node
        when Hash then "an object"
        when Array then "an array"
        when nil then "null"
        else node.inspect
        end
      end

      def message(klass, node)
        special = SPECIAL[klass.descriptor.full_name]
        return send(special, klass, node) if special
        fail!("expected an object for #{klass.descriptor.full_name}, got #{describe(node)}") unless node.is_a?(Hash)
        msg = klass.new
        fields(msg, node)
        msg
      end

      def fields(msg, node)
        klass = msg.class
        descriptor = klass.descriptor
        oneofs = nil
        seen = {}
        extensions = nil
        node.each do |key, value|
          if key.start_with?("[") && key.end_with?("]")
            extension(msg, key[1..-2], value, extensions ||= {})
            next
          end
          field = descriptor.fields_by_json_name[key] || descriptor.fields_by_name[key]
          unless field
            next if @ignore_unknown
            fail!("#{descriptor.full_name} has no field #{key.inspect}")
          end
          info = klass.__by_number.fetch(field.number)
          @path << info.name
          fail!("field #{info.name} is given more than once") if seen[info.number]
          seen[info.number] = true
          if value.nil? && (info.repeated || info.map || !null_is_value?(info))
            @path.pop
            next
          end
          if (oneof = field.real_oneof)
            oneofs ||= {}
            fail!("more than one field of oneof #{oneof.name} is set") if oneofs[oneof]
          end
          parsed = field_value(info, value)
          unless parsed.equal?(SKIP)
            oneofs[oneof] = true if oneof
            begin
              msg.__set(info.index, parsed)
            rescue Protostar::TypeError => e
              fail!(e.message)
            end
          end
          @path.pop
        end
        add_extensions(msg, extensions) if extensions
      end

      # An extension given as "[full.name]": its values are collected, then
      # kept where the binary codec keeps them, in the unknown fields
      def extension(msg, name, value, collected)
        @extensions ||= Text::Extensions.new(@registry, nil)
        field = @extensions.named(msg.class.descriptor, name)
        info = field && @extensions.info(field)
        unless info
          return if @ignore_unknown
          fail!("#{msg.class.descriptor.full_name} has no extension #{name.inspect}")
        end
        fail!("extension #{name} is given more than once") if collected.key?(info)
        @path << "[#{name}]"
        if !value.nil? || (!info.repeated && null_is_value?(info))
          parsed = field_value(info, value)
          collected[info] = info.repeated ? parsed : [parsed] unless parsed.equal?(SKIP)
        end
        @path.pop
      end

      def add_extensions(msg, collected)
        collected.sort_by { |info, _| info.number }.each do |info, values|
          @extensions.write(info, values).each { |u| msg.__add_unknown(u) }
        end
        msg.__seal_unknown
      end

      # null is the null of Value and NullValue fields, and absence everywhere else
      def null_is_value?(info)
        if info.kind == F::ENUM
          info.enum_module.descriptor.full_name == NULL_VALUE
        elsif info.message?
          info.message_class.descriptor.full_name == VALUE
        else
          false
        end
      end

      def field_value(info, value)
        if info.map
          fail!("expected an object for a map, got #{describe(value)}") unless value.is_a?(Hash)
          out = {}
          value.each do |k, v|
            @path << Path::MapKey.new(k)
            key = map_key(info.key, k)
            parsed = element(info.value, v)
            out[key] = parsed unless parsed.equal?(SKIP)
            @path.pop
          end
          out
        elsif info.repeated
          fail!("expected an array, got #{describe(value)}") unless value.is_a?(Array)
          out = []
          value.each_with_index do |v, i|
            @path << i
            parsed = element(info, v)
            out << parsed unless parsed.equal?(SKIP)
            @path.pop
          end
          out
        else
          single(info, value)
        end
      end

      # An element of a repeated field or a map value, where null is not absence
      def element(info, value)
        fail!("null is not allowed here") if value.nil? && !null_is_value?(info)
        single(info, value)
      end

      def map_key(info, key)
        case info.kind
        when F::STRING then key
        when F::BOOL
          case key
          when "true" then true
          when "false" then false
          else fail!("map key #{key.inspect} is not true or false")
          end
        else integer(info, key)
        end
      end

      def single(info, value)
        case info.kind
        when F::DOUBLE, F::FLOAT then float(info, value)
        when F::BOOL
          fail!("expected true or false, got #{describe(value)}") unless value == true || value == false
          value
        when F::STRING
          fail!("expected a string, got #{describe(value)}") unless value.is_a?(String)
          fail!("string is not valid UTF-8") unless value.valid_encoding?
          value
        when F::BYTES then bytes(value)
        when F::ENUM then enum(info, value)
        when F::MESSAGE, F::GROUP then message(info.message_class, value)
        else integer(info, value)
        end
      end

      def integer(info, value)
        value = Float(value) if value.is_a?(String) && !QUOTED_INTEGER.match?(value) && QUOTED_INTEGRAL.match?(value)
        n = case value
        when Integer, Float
          f = value.to_f
          limit = (info.kind == F::UINT64 || info.kind == F::FIXED64) ? UINT64_LIMIT : INT64_LIMIT
          fail!("number #{value} is out of range") unless f.finite? && f < limit && f >= ((limit == INT64_LIMIT) ? -limit : 0)
          fail!("number #{value} is not an integer") unless f == f.truncate
          f.to_i
        when String
          fail!("#{value.inspect} is not an integer") unless QUOTED_INTEGER.match?(value)
          Integer(value, 10)
        else
          fail!("expected an integer, got #{describe(value)}")
        end
        range = RANGES.fetch((info.kind == F::ENUM) ? F::INT32 : info.kind)
        fail!("#{n} is out of range for #{info.descriptor.type}") unless range.cover?(n)
        n
      end

      def float(info, value)
        f = case value
        when Integer, Float then value.to_f
        when String
          NONFINITE.fetch(value) do
            fail!("#{value.inspect} is not a number") unless QUOTED_FLOAT.match?(value)
            Float(value.strip).tap { |x| fail!("#{value} is out of range") unless x.finite? }
          end
        else fail!("expected a number, got #{describe(value)}")
        end
        fail!("#{value} is out of range") if value.is_a?(Numeric) && !f.finite?
        if info.kind == F::FLOAT
          single = Message::Coercion.float32(f)
          fail!("#{value} is out of range for float") if f.finite? && !single.finite?
          single
        else
          f
        end
      end

      # Standard or URL-safe base64, padded or not
      def bytes(value)
        fail!("expected a base64 string, got #{describe(value)}") unless value.is_a?(String)
        size = value.bytesize
        padded = value.end_with?("=")
        unless BASE64.match?(value) && (padded ? size % 4 == 0 : size % 4 != 1)
          fail!("#{value.inspect} is not base64")
        end
        s = value.tr("-_", "+/")
        s = s.delete_suffix("=").delete_suffix("=")
        s << "=" * ((4 - s.bytesize % 4) % 4)
        s.unpack1("m").force_encoding(Encoding::BINARY)
      end

      def enum(info, value)
        if value.nil?
          0
        elsif value.is_a?(String)
          number = info.enum_numbers[value.to_sym]
          return number if number
          return SKIP if @ignore_unknown
          fail!("#{info.enum_module.descriptor.full_name} has no value #{value.inspect}")
        elsif value.is_a?(Integer) || value.is_a?(Float)
          n = integer(info, value)
          if info.closed_enum && !info.enum_names.key?(n)
            return SKIP if @ignore_unknown
            fail!("#{info.enum_module.descriptor.full_name} has no value #{n}")
          end
          n
        else
          fail!("expected an enum name or number, got #{describe(value)}")
        end
      end

      def wrapper(klass, node)
        info = klass.__by_name.fetch("value")
        @path << "value"
        v = single(info, node)
        @path.pop
        msg = klass.new
        msg.__set(info.index, v)
        msg
      end

      def timestamp(klass, node)
        fail!("expected an RFC 3339 timestamp string, got #{describe(node)}") unless node.is_a?(String)
        m = TIMESTAMP.match(node) or fail!("#{node.inspect} is not an RFC 3339 timestamp")
        fail!("#{node.inspect} has more than 9 fractional digits") if m[7] && m[7].size > 9
        days = days_from_civil(m[1].to_i, m[2].to_i, m[3].to_i)
        seconds = days * 86_400 + m[4].to_i * 3600 + m[5].to_i * 60 + m[6].to_i
        unless m[8]
          offset = m[10].to_i * 3600 + m[11].to_i * 60
          seconds += (m[9] == "-") ? offset : -offset
        end
        unless (Encoder::TIMESTAMP_MIN..Encoder::TIMESTAMP_MAX).cover?(seconds)
          fail!("#{node.inspect} is out of the Timestamp range")
        end
        klass.new(seconds: seconds, nanos: nanos(m[7]))
      end

      # Days since 1970-01-01 of a proleptic Gregorian date; like upb, it
      # does not check that the day exists in the month
      def days_from_civil(y, m, d)
        y -= 1 if m <= 2
        era = y.div(400)
        yoe = y - era * 400
        doy = (153 * (m + ((m > 2) ? -3 : 9)) + 2) / 5 + d - 1
        doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        era * 146_097 + doe - 719_468
      end

      def nanos(digits)
        return 0 if digits.nil? || digits.empty?
        digits.ljust(9, "0").to_i
      end

      def duration(klass, node)
        fail!("expected a duration string, got #{describe(node)}") unless node.is_a?(String)
        m = DURATION.match(node)
        fail!("#{node.inspect} is not a duration") if m.nil? || (m[2].empty? && m[3].to_s.empty?)
        fail!("#{node.inspect} has more than 9 fractional digits") if m[3] && m[3].size > 9
        seconds = m[2].empty? ? 0 : m[2].to_i
        fail!("#{node.inspect} is out of the Duration range") if seconds > Encoder::DURATION_MAX
        nanos = nanos(m[3])
        if m[1]
          seconds = -seconds
          nanos = -nanos
        end
        klass.new(seconds: seconds, nanos: nanos)
      end

      def field_mask(klass, node)
        fail!("expected a field mask string, got #{describe(node)}") unless node.is_a?(String)
        paths = node.empty? ? [] : node.split(",", -1)
        paths.map! do |p|
          fail!("field mask path #{p.inspect} may not contain '_'") if p.include?("_")
          p.gsub(/[A-Z]/) { "_#{$&.downcase}" }
        end
        klass.new(paths: paths)
      end

      def struct(klass, node)
        fail!("expected an object for google.protobuf.Struct, got #{describe(node)}") unless node.is_a?(Hash)
        value_class = klass.__by_name.fetch("fields").value.message_class
        fields = {}
        node.each do |k, v|
          @path << Path::MapKey.new(k)
          fields[k] = value(value_class, v)
          @path.pop
        end
        klass.new(fields: fields)
      end

      def list_value(klass, node)
        fail!("expected an array for google.protobuf.ListValue, got #{describe(node)}") unless node.is_a?(Array)
        value_class = klass.__by_name.fetch("values").message_class
        values = node.each_with_index.map do |v, i|
          @path << i
          parsed = value(value_class, v)
          @path.pop
          parsed
        end
        klass.new(values: values)
      end

      def value(klass, node)
        case node
        when nil then klass.new(null_value: 0)
        when true, false then klass.new(bool_value: node)
        when String then klass.new(string_value: node)
        when Integer, Float
          f = node.to_f
          fail!("#{node} is out of range") unless f.finite?
          klass.new(number_value: f)
        when Hash then klass.new(struct_value: struct(klass.__by_name.fetch("struct_value").message_class, node))
        when Array then klass.new(list_value: list_value(klass.__by_name.fetch("list_value").message_class, node))
        end
      end

      def any(klass, node)
        fail!("expected an object for google.protobuf.Any, got #{describe(node)}") unless node.is_a?(Hash)
        return klass.new if node.empty?
        url = node["@type"]
        fail!("Any has no \"@type\"") if url.nil?
        fail!("\"@type\" of Any must be a string") unless url.is_a?(String)
        slash = url.rindex("/")
        fail!("type URL #{url.inspect} needs a '/' and a non-empty host") if slash.nil? || slash == 0
        name = url[(slash + 1)..]
        inner_class = Types.find(name, registry: @registry || Types.registry)
        fail!("cannot find the type #{name.inspect} of an Any") unless inner_class.is_a?(Class)
        rest = node.except("@type")
        inner = if SPECIAL.key?(inner_class.descriptor.full_name)
          rest.each_key do |k|
            next if k == "value" || @ignore_unknown
            fail!("Any holding a #{inner_class.descriptor.full_name} has no field #{k.inspect}")
          end
          rest.key?("value") ? element_message(inner_class, rest["value"]) : inner_class.new
        else
          message(inner_class, rest)
        end
        klass.new(type_url: url, value: inner.encode)
      end

      def element_message(klass, node)
        @path << "value"
        msg = message(klass, node)
        @path.pop
        msg
      end
    end
  end
end
