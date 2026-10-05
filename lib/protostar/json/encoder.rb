# frozen_string_literal: true

module Protostar
  module JSON
    # Writes a message as proto3 JSON the way google-protobuf's Ruby gem
    # does: compact, fields in declaration order, unknown fields left out.
    # @api private
    class Encoder
      F = Message::FieldInfo

      # Messages whose JSON is not an object of their fields
      SPECIAL = {
        "google.protobuf.Any" => :any,
        "google.protobuf.Timestamp" => :timestamp,
        "google.protobuf.Duration" => :duration,
        "google.protobuf.FieldMask" => :field_mask,
        "google.protobuf.Struct" => :struct,
        "google.protobuf.Value" => :value,
        "google.protobuf.ListValue" => :list_value,
        "google.protobuf.DoubleValue" => :wrapper,
        "google.protobuf.FloatValue" => :wrapper,
        "google.protobuf.Int64Value" => :wrapper,
        "google.protobuf.UInt64Value" => :wrapper,
        "google.protobuf.Int32Value" => :wrapper,
        "google.protobuf.UInt32Value" => :wrapper,
        "google.protobuf.BoolValue" => :wrapper,
        "google.protobuf.StringValue" => :wrapper,
        "google.protobuf.BytesValue" => :wrapper
      }.freeze

      NULL_VALUE = "google.protobuf.NullValue"

      ESCAPES = (0..0x1f).to_h { |b| [b.chr, format("\\u%04x", b)] }.merge(
        "\n" => "\\n", "\r" => "\\r", "\t" => "\\t", "\f" => "\\f", "\b" => "\\b", "\"" => "\\\"", "\\" => "\\\\"
      ).freeze
      ESCAPED = /["\\\x00-\x1f]/

      # Seconds of 0001-01-01T00:00:00Z and 9999-12-31T23:59:59Z
      TIMESTAMP_MIN = -62_135_596_800
      TIMESTAMP_MAX = 253_402_300_799
      DURATION_MAX = 315_576_000_000

      # @param preserve_proto_field_names [Boolean] field names as in the .proto, not lowerCamel
      # @param emit_defaults [Boolean] also fields without presence at their default, and empty
      #   repeated fields and maps; never unset message fields or oneof members
      # @param format_enums_as_integers [Boolean]
      # @param registry [Types::Registry] where the types inside Any are looked up
      def initialize(preserve_proto_field_names: false, emit_defaults: false, format_enums_as_integers: false,
        registry: Types.registry, preserve_proto_fieldnames: nil)
        @proto_names = preserve_proto_fieldnames.nil? ? preserve_proto_field_names : preserve_proto_fieldnames
        @emit_defaults = emit_defaults
        @enums_as_integers = format_enums_as_integers
        @registry = registry
        @path = []
      end

      # @param message [Message]
      # @return [String] UTF-8
      def encode(message)
        out = +""
        message(message, out)
        out.force_encoding(Encoding::UTF_8)
      end

      private

      def message(msg, out)
        special = SPECIAL[msg.class.descriptor.full_name]
        if special
          send(special, msg, out)
        else
          out << "{"
          fields(msg, out, true)
          out << "}"
        end
      end

      # Writes the fields of a message, each preceded by a comma unless it is
      # the first; returns whether nothing was written
      def fields(msg, out, first)
        values = msg.__values
        msg.class.__fields.each do |info|
          v = values[info.index]
          if @emit_defaults
            next if v.nil? && info.presence
          elsif v.nil?
            next
          elsif info.map || info.repeated
            next if v.empty?
          elsif !info.presence && info.zero?(v)
            next
          end
          out << "," unless first
          first = false
          string(@proto_names ? info.name : info.descriptor.json_name, out)
          out << ":"
          @path << info.name
          if info.map
            map(info, v || Message::EMPTY_HASH, out)
          elsif info.repeated
            out << "["
            (v || Message::EMPTY_ARRAY).each_with_index do |e, i|
              out << "," unless i == 0
              @path << i
              single(info, e, out)
              @path.pop
            end
            out << "]"
          else
            single(info, v, out)
          end
          @path.pop
        end
        first
      end

      def map(info, hash, out)
        key = info.key
        value = info.value
        out << "{"
        first = true
        hash.each do |k, v|
          out << "," unless first
          first = false
          if key.kind == F::STRING
            string(k, out)
          else
            out << "\"" << k.to_s << "\""
          end
          out << ":"
          @path << Path::MapKey.new(k)
          single(value, v, out)
          @path.pop
        end
        out << "}"
      end

      def single(info, v, out)
        case info.kind
        when F::INT32, F::SINT32, F::SFIXED32, F::UINT32, F::FIXED32 then out << v.to_s
        when F::INT64, F::SINT64, F::SFIXED64, F::UINT64, F::FIXED64 then out << "\"" << v.to_s << "\""
        when F::DOUBLE then double(v, out)
        when F::FLOAT then float(v, out)
        when F::BOOL then out << (v ? "true" : "false")
        when F::STRING then string(v, out)
        when F::BYTES then out << "\"" << [v].pack("m0") << "\""
        when F::ENUM then enum(info, v, out)
        else message(v, out)
        end
      end

      def enum(info, v, out)
        if info.enum_module.descriptor.full_name == NULL_VALUE
          out << "null"
        elsif v.is_a?(Symbol) && !@enums_as_integers
          out << "\"" << v.name << "\""
        else
          out << (v.is_a?(Symbol) ? info.enum_numbers.fetch(v) : v).to_s
        end
      end

      def string(s, out)
        # strings without UTF-8 validation (proto2) can hold anything
        s = s.scrub unless s.valid_encoding?
        out << "\"" << (ESCAPED.match?(s) ? s.gsub(ESCAPED, ESCAPES) : s) << "\""
      end

      # upb's round-trip form: 15 significant digits, or 17 when 15 do not read back
      def double(v, out)
        return out << nonfinite(v) unless v.finite?
        s = format("%.15g", v)
        back = Float(s)
        s = format("%.17g", v) unless back == v
        out << s
      end

      # Same for single precision: 6 digits, or 9
      def float(v, out)
        return out << nonfinite(v) unless v.finite?
        s = format("%.6g", v)
        s = format("%.9g", v) unless Message::Coercion.float32(Float(s)) == v
        out << s
      end

      def nonfinite(v)
        if v.nan? then "\"NaN\""
        elsif v > 0 then "\"Infinity\""
        else "\"-Infinity\""
        end
      end

      def fail!(message)
        raise EncodeError.new(message, Path.to_s(@path))
      end

      def get(msg, name)
        msg.__values[msg.class.__by_name.fetch(name).index]
      end

      def any(msg, out)
        url = get(msg, "type_url") || ""
        value = get(msg, "value") || ""
        klass = any_class(url)
        inner = begin
          klass.decode(value)
        rescue DecodeError => e
          fail!("cannot decode the #{klass.descriptor.full_name} inside Any: #{e.message}")
        end
        out << "{\"@type\":"
        string(url, out)
        if SPECIAL.key?(klass.descriptor.full_name)
          out << ",\"value\":"
          message(inner, out)
        else
          fields(inner, out, false)
        end
        out << "}"
      end

      def any_class(url)
        slash = url.rindex("/")
        fail!("bad type URL #{url.inspect} in Any") if slash.nil? || slash == 0
        name = url[(slash + 1)..]
        klass = Types.find(name, registry: @registry)
        fail!("cannot find the type #{name.inspect} of an Any") unless klass.is_a?(Class)
        klass
      end

      def timestamp(msg, out)
        seconds = get(msg, "seconds") || 0
        nanos = get(msg, "nanos") || 0
        fail!("Timestamp before 0001-01-01T00:00:00Z") if seconds < TIMESTAMP_MIN
        fail!("Timestamp after 9999-12-31T23:59:59Z") if seconds > TIMESTAMP_MAX
        fail!("Timestamp nanos out of range: #{nanos}") unless (0..999_999_999).cover?(nanos)
        time = ::Time.at(seconds).utc
        out << "\"" << time.strftime("%Y-%m-%dT%H:%M:%S") << fraction(nanos) << "Z\""
      end

      def duration(msg, out)
        seconds = get(msg, "seconds") || 0
        nanos = get(msg, "nanos") || 0
        fail!("Duration out of range: #{seconds}s") if seconds.abs > DURATION_MAX
        fail!("Duration nanos out of range: #{nanos}") if nanos.abs > 999_999_999
        fail!("Duration seconds and nanos have different signs") if (seconds < 0 && nanos > 0) || (seconds > 0 && nanos < 0)
        out << "\""
        out << "-" if seconds < 0 || nanos < 0
        out << seconds.abs.to_s << fraction(nanos.abs) << "s\""
      end

      # 0, 3, 6 or 9 digits, as few as the value needs
      def fraction(nanos)
        if nanos == 0 then ""
        elsif nanos % 1_000_000 == 0 then format(".%03d", nanos / 1_000_000)
        elsif nanos % 1000 == 0 then format(".%06d", nanos / 1000)
        else format(".%09d", nanos)
        end
      end

      def field_mask(msg, out)
        paths = get(msg, "paths") || Message::EMPTY_ARRAY
        camel = paths.map do |path|
          fail!("FieldMask path #{path.inspect} has an upper-case letter and cannot round-trip through JSON") if /[A-Z]/.match?(path)
          if /_(?![a-z])/.match?(path)
            fail!("FieldMask path #{path.inspect} has an underscore not followed by a lower-case letter and cannot round-trip through JSON")
          end
          path.gsub(/_([a-z])/) { $1.upcase }
        end
        string(camel.join(","), out)
      end

      def struct(msg, out)
        info = msg.class.__by_name.fetch("fields")
        map(info, get(msg, "fields") || Message::EMPTY_HASH, out)
      end

      def list_value(msg, out)
        out << "["
        (get(msg, "values") || Message::EMPTY_ARRAY).each_with_index do |v, i|
          out << "," unless i == 0
          @path << i
          message(v, out)
          @path.pop
        end
        out << "]"
      end

      def value(msg, out)
        kind = msg.which_kind
        fail!("Value has no kind set") unless kind
        info = msg.class.__by_name.fetch(kind)
        v = msg.__values[info.index]
        case info.name
        when "null_value" then out << "null"
        when "number_value"
          fail!("Value cannot hold #{v}, which would read back as a string") unless v.finite?
          double(v, out)
        else single(info, v, out)
        end
      end

      def wrapper(msg, out)
        info = msg.class.__by_name.fetch("value")
        single(info, msg.__values[info.index] || info.default, out)
      end
    end
  end
end
