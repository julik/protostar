# frozen_string_literal: true

module Protostar
  module Text
    # Extensions seen through the unknown fields that hold them: finding the
    # extensions of a message, reading their values out of unknown fields
    # and writing values back into unknown fields.
    # @api private
    class Extensions
      F = Message::FieldInfo

      # @param registry [Types::Registry]
      # @param pool [Schema::Pool, nil]
      def initialize(registry, pool)
        @registry = registry
        @pool = pool
        @by_extendee = {}
        @infos = {}
      end

      # @param descriptor [Schema::Message]
      # @return [Hash{Integer => Schema::Field}] extensions of the message by number
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

      # @param descriptor [Schema::Message]
      # @param name [String] the extension's full name
      # @return [Schema::Field, nil]
      def named(descriptor, name)
        of(descriptor).each_value.find { |f| f.full_name == name }
      end

      # @param field [Schema::Field] an extension
      # @return [Message::FieldInfo, nil] nil when its message or enum type has no class
      def info(field)
        return @infos[field] if @infos.key?(field)
        @infos[field] = begin
          Message::FieldInfo.new(field, nil, method(:resolve))
        rescue KeyError
          nil
        end
      end

      # The values an extension holds in a message's unknown fields
      # @param info [Message::FieldInfo]
      # @param unknown [Array<UnknownField>] those with the extension's number
      # @return [Array] values as the field's reader would give them, or nil
      #   when the bytes do not read as the extension's type
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

      # @param info [Message::FieldInfo]
      # @param values [Array]
      # @return [Array<UnknownField>] the fields the binary codec would have kept
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
