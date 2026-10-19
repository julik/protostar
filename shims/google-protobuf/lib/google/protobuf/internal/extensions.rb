# frozen_string_literal: true

module Google
  module Protobuf
    module Internal
      # Extension values live in a message's unknown fields, as protostar
      # keeps them; these read them out and write them back by the
      # extension's FieldDescriptor.
      module Extensions # :nodoc: all
        ITEM = 1 # MessageSet item group
        TYPE_ID = 2
        MESSAGE = 3

        module_function

        # Returns the extension's values on the message, as stored.
        #: (untyped msg, untyped fd) -> Array[untyped]
        def read(msg, fd)
          info = info(fd)
          if message_set?(msg)
            items(msg).filter_map { |type_id, bytes| info.message_class.decode(bytes) if type_id == fd.number }
          else
            found = msg.unknown_fields.select { |u| u.number == fd.number }
            codec(fd).read(info, found) || []
          end
        end

        # Replaces the extension's values on the message
        def write(msg, fd, values)
          info = info(fd)
          kept = msg.unknown_fields.reject { |u| holds?(msg, u, fd) }
          added = if message_set?(msg)
            values.map { |v| item(fd.number, v.encode) }
          else
            codec(fd).write(info, values)
          end
          msg.__greplace_unknown(kept + added)
        end

        def holds?(msg, unknown, fd)
          if message_set?(msg)
            unknown.number == ITEM && unknown.wire_type == Protostar::Wire::START_GROUP &&
              item_type_id(unknown.bytes) == fd.number
          else
            unknown.number == fd.number
          end
        end

        def message_set?(msg)
          msg.class.descriptor.__schema.message_set_wire_format?
        end

        def info(fd)
          codec(fd).info(fd.__schema) || raise(TypeError, "extension #{fd.name} has no class for its type")
        end

        def codec(fd)
          fd.descriptor_pool.__extension_codec
        end

        # Returns each MessageSet item's type id and message bytes.
        #: (untyped msg) -> Array[[Integer, String]]
        def items(msg)
          msg.unknown_fields.filter_map do |u|
            next unless u.number == ITEM && u.wire_type == Protostar::Wire::START_GROUP
            type_id = message = nil
            r = Protostar::Wire::Reader.new(u.bytes)
            until r.eof?
              number, wire_type = r.read_tag
              break if wire_type == Protostar::Wire::END_GROUP
              if number == TYPE_ID && wire_type == Protostar::Wire::VARINT
                type_id = r.read_varint
              elsif number == MESSAGE && wire_type == Protostar::Wire::LENGTH_DELIMITED
                message = r.read_bytes
              else
                r.skip_field(number, wire_type)
              end
            end
            [type_id, message] if type_id && message
          end
        end

        def item_type_id(bytes)
          r = Protostar::Wire::Reader.new(bytes)
          until r.eof?
            number, wire_type = r.read_tag
            return nil if wire_type == Protostar::Wire::END_GROUP
            return r.read_varint if number == TYPE_ID && wire_type == Protostar::Wire::VARINT
            r.skip_field(number, wire_type)
          end
          nil
        end

        def item(type_id, bytes)
          w = Protostar::Wire::Writer.new
          w.write_tag(TYPE_ID, Protostar::Wire::VARINT)
          w.write_varint(type_id)
          w.write_tag(MESSAGE, Protostar::Wire::LENGTH_DELIMITED)
          w.write_bytes(bytes)
          w.write_tag(ITEM, Protostar::Wire::END_GROUP)
          Protostar::UnknownField.new(ITEM, Protostar::Wire::START_GROUP, w.string.b.freeze)
        end
      end

      module MessageMethods
        def __greplace_unknown(fields) # :nodoc:
          @unknown = fields.empty? ? nil : fields.freeze
        end

        private

        def __gext_get(fd)
          values = Extensions.read(self, fd)
          if fd.repeated?
            RepeatedField.__for_field(fd, values)
          elsif values.empty?
            fd.default
          else
            values.last
          end
        end

        def __gext_has?(fd)
          !Extensions.read(self, fd).empty?
        end

        def __gext_set(fd, value)
          values = if fd.repeated?
            raise TypeError, "Expected repeated field array" unless value.is_a?(RepeatedField)
            value.to_a
          elsif value.nil?
            []
          else
            [Convert.to_store(value, fd.type, fd.subtype, fd.name)]
          end
          Extensions.write(self, fd, values)
          value
        end

        def __gext_clear(fd)
          Extensions.write(self, fd, [])
          nil
        end
      end
    end

    class DescriptorPool
      def __extension_codec # :nodoc:
        @extension_codec ||= Protostar::Text::Extensions.new(@registry, @schema_pool)
      end
    end
  end
end
