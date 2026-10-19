# frozen_string_literal: true

module Protostar
  module Text
    # Extensions seen through the unknown fields that hold them: finding the
    # extensions of a message, reading their values out of unknown fields
    # and writing values back into unknown fields.
    class Extensions # :nodoc: all
      F = Message::FieldInfo

      #: (Types::Registry registry, Schema::Pool? pool) -> void
      def initialize(registry, pool)
        @registry = registry
        @pool = pool
        @by_extendee = {}
        @infos = {}
      end

      # Returns extensions of the message by number.
      #: (Schema::Message descriptor) -> Hash[Integer, Schema::Field]
      def of(descriptor)
        @by_extendee[descriptor] ||= begin
          fields = if @pool
            @pool.extensions_of(descriptor.full_name)
          else
            files(descriptor.file).flat_map(&:all_extensions).select { |e| e.extendee.equal?(descriptor) }
          end
          fields.to_h { |f| [f.number, f] }
        end
      end

      # - `name`: the extension's full name
      #: (Schema::Message descriptor, String name) -> Schema::Field?
      def named(descriptor, name)
        of(descriptor).each_value.find { |f| f.full_name == name }
      end

      # - `field`: an extension
      #
      # Returns nil when its message or enum type has no class.
      #: (Schema::Field field) -> Message::FieldInfo?
      def info(field)
        return @infos[field] if @infos.key?(field)
        @infos[field] = begin
          Message::FieldInfo.new(field, nil, method(:resolve))
        rescue KeyError
          nil
        end
      end

      # The values an extension holds in a message's unknown fields
      #
      # - `unknown`: those with the extension's number
      #
      # Returns the values as the field's reader would give them, or nil
      # when the bytes do not read as the extension's type.
      #: (Message::FieldInfo info, Array[UnknownField] unknown) -> Array[untyped]?
      def read(info, unknown)
        values = []
        unknown.each do |u|
          if u.wire_type == Wire::LENGTH_DELIMITED && info.packable && !info.message? && info.kind != F::STRING && info.kind != F::BYTES
            r = Wire::Reader.new(u.value)
            values << scalar(info, r) until r.eof?
          elsif u.wire_type != info.wire_type
            return nil
          elsif info.message?
            values << info.message_class.decode(u.value)
          else
            values << scalar(info, Wire::Reader.new(u.bytes))
          end
        end
        values
      rescue DecodeError
        nil
      end

      # Returns the fields the binary codec would have kept.
      #: (Message::FieldInfo info, Array[untyped] values) -> Array[UnknownField]
      def write(info, values)
        if info.packed && !values.empty?
          w = Wire::Writer.new
          Codec::Encoder.packed(info, values, w)
          payload = w.string
          return [UnknownField.new(info.number, Wire::LENGTH_DELIMITED, Wire.varint(payload.bytesize) + payload)]
        end
        values.map do |v|
          w = Wire::Writer.new
          sizes = {}.compare_by_identity
          Codec::Sizer.value(info, v, sizes)
          Codec::Encoder.value(info, v, w, sizes)
          UnknownField.new(info.number, info.wire_type, w.string)
        end
      end

      private

      def scalar(info, r)
        v = Codec::Decoder.scalar(r, info)
        (info.kind == F::ENUM) ? (info.enum_names[v] || v) : v
      end

      def resolve(descriptor)
        Types.find(descriptor.full_name, registry: @registry || Types.registry) || raise(KeyError, descriptor.full_name)
      end

      # The file and everything it imports, transitively
      def files(file, seen = {})
        return [] if seen[file]
        seen[file] = true
        [file] + file.dependency_files.flat_map { |d| files(d, seen) }
      end
    end
  end
end
