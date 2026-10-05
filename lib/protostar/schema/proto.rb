# frozen_string_literal: true

module Protostar
  @generated_pool = Schema::Pool.new

  class << self
    # @return [Schema::Pool] the process-wide pool generated `_pb.rb` files build into
    attr_reader :generated_pool

    # Builds every file of a serialized `FileDescriptorSet` into a pool, in
    # order. Custom options are decoded against the extensions the pool (and
    # the file itself) defines; files already in the pool are taken from it.
    # @param bytes [String] a serialized google.protobuf.FileDescriptorSet
    # @param pool [Schema::Pool]
    # @return [Array<Schema::File>]
    def load_descriptor_set(bytes, pool:)
      Schema::Proto.each_file(bytes).map { |file_bytes| Schema::Proto.load_file(file_bytes, pool) }
    end
  end

  Pool = Schema::Pool

  module Schema
    # Descriptors as descriptor.proto messages and bytes. Hashes are written
    # and read by a codec driven by {Schema} descriptors, so custom options
    # of any type are encoded from `:__extensions` and decoded back into it;
    # the bootstrap's message classes are used only at the edges.
    # @api private
    module Proto
      # The descriptor.proto message types the bootstrap defines
      def self.types
        require "protostar/google/protobuf/descriptor_pb"
        ::Protostar::Google::Protobuf
      end

      # @return [Schema::Message] descriptor.proto's own descriptor of a message
      def self.schema(name)
        types.const_get(name).descriptor
      end

      # @param bytes [String] a serialized FileDescriptorSet
      # @return [Array<String>] each serialized FileDescriptorProto
      def self.each_file(bytes)
        r = Wire::Reader.new(bytes)
        files = []
        until r.eof?
          number, wire_type = r.read_tag
          if number == 1 && wire_type == Wire::LENGTH_DELIMITED
            files << r.read_bytes
          else
            r.skip_field(number, wire_type)
          end
        end
        files
      end

      # Decodes, builds and adds one serialized FileDescriptorProto
      def self.load_file(bytes, pool)
        name = HashCodec.decode(schema(:FileDescriptorProto), bytes, nil, keep_unknown: false)[:name]
        existing = pool.file(name)
        return existing if existing
        pool.add(build(bytes, pool))
      end

      # Decodes a serialized FileDescriptorProto into a hash and builds it. A
      # first pass leaves the file's own extensions unknown; when its options
      # need them, a structural build of the file supplies them for a second.
      def self.build(bytes, pool)
        type = schema(:FileDescriptorProto)
        lookup = ->(extendee, number) { pool.find_extension(extendee, number) }
        hash = HashCodec.decode(type, bytes, lookup, keep_unknown: false)
        own = HashCodec.unknown?(hash) ? own_extensions(hash, pool) : {}
        unless own.empty?
          lookup = ->(extendee, number) { pool.find_extension(extendee, number) || own[[extendee, number]] }
          hash = HashCodec.decode(type, bytes, lookup, keep_unknown: false)
        end
        Builder.build(hash, pool: pool)
      end

      # The extensions a file defines, from a build of its first-pass hash
      # (options it cannot read yet are kept as unknown fields there)
      def self.own_extensions(hash, pool)
        first = Builder.build(hash, pool: pool)
        first.all_extensions.to_h { |e| [[e.extendee.full_name, e.number], e] }
      end

      # Encodes and decodes descriptor-shaped hashes by {Schema::Message}:
      # known fields by name, extensions under `:__extensions` by full
      # name, unknown fields under `:__unknown_fields` as `[number, wire_type,
      # bytes]` with the bytes that followed the tag. Map fields are Arrays of
      # `{key:, value:}` entries, enums Symbols (Integers when unnamed).
      module HashCodec
        module_function

        # @param type [Schema::Message]
        # @param hash [Hash]
        # @param extension [#call] full name to the extension's {Schema::Field}
        # @return [String] binary, fields in number order, unknown fields last
        def encode(type, hash, extension)
          entries = []
          unknown = nil
          hash.each do |key, value|
            case key
            when :__extensions
              value.each do |name, v|
                field = extension.call(name) || raise(Error, "extension #{name} of #{type.full_name} is not known")
                entries << [field, v]
              end
            when :__unknown_fields then unknown = value
            else
              field = type.fields_by_name[key.to_s] || raise(Error, "#{type.full_name} has no field #{key}")
              entries << [field, value]
            end
          end
          out = "".b
          w = Wire::Writer.new(out)
          entries.sort_by! { |f, _| f.number }
          entries.each do |field, value|
            if field.extension? && type.message_set_wire_format?
              write_set_item(w, field, value, extension)
            else
              write_field(w, field, value, extension)
            end
          end
          unknown&.each do |number, wire_type, bytes|
            w.write_tag(number, wire_type)
            w.write_raw(bytes)
          end
          w.flush
          out
        end

        # A MessageSet item: group 1 holding type_id 2 and message 3
        def write_set_item(w, field, value, extension)
          w.write_tag(1, Wire::START_GROUP)
          w.write_tag(2, Wire::VARINT)
          w.write_varint(field.number)
          w.write_tag(3, Wire::LENGTH_DELIMITED)
          w.write_bytes(encode(field.message_type, value, extension))
          w.write_tag(1, Wire::END_GROUP)
        end

        def write_field(w, field, value, extension)
          if field.repeated?
            return if value.empty?
            if field.packed?
              body = "".b
              inner = Wire::Writer.new(body)
              value.each { |v| write_value(inner, field, v, extension) }
              inner.flush
              w.write_tag(field.number, Wire::LENGTH_DELIMITED)
              w.write_bytes(body)
            else
              value.each { |v| write_one(w, field, v, extension) }
            end
          else
            return if !field.presence? && zero?(field, value)
            write_one(w, field, value, extension)
          end
        end

        def zero?(field, value)
          case field.type
          when :string, :bytes then value.empty?
          when :bool then !value
          when :enum then value == 0 || (value.is_a?(Symbol) && field.enum_type.value(value.to_s)&.number == 0)
          when :double, :float then value == 0 && !(1.0 / value).negative?
          else value == 0
          end
        end

        def write_one(w, field, value, extension)
          case field.type
          when :message
            w.write_tag(field.number, Wire::LENGTH_DELIMITED)
            w.write_bytes(encode(field.message_type, value, extension))
          when :group
            w.write_tag(field.number, Wire::START_GROUP)
            w.write_raw(encode(field.message_type, value, extension))
            w.write_tag(field.number, Wire::END_GROUP)
          else
            w.write_tag(field.number, field.wire_type)
            write_value(w, field, value, extension)
          end
        end

        def write_value(w, field, v, _extension)
          case field.type
          when :int32, :int64, :uint32, :uint64 then w.write_varint(v)
          when :sint32, :sint64 then w.write_zigzag(v)
          when :bool then w.write_varint(v ? 1 : 0)
          when :enum
            number = v.is_a?(Integer) ? v : field.enum_type.value(v.to_s)&.number
            raise Error, "#{v.inspect} is not a value of #{field.enum_type.full_name}" unless number
            w.write_varint(number)
          when :fixed32 then w.write_fixed32(v)
          when :fixed64 then w.write_fixed64(v)
          when :sfixed32 then w.write_sfixed32(v)
          when :sfixed64 then w.write_sfixed64(v)
          when :float then w.write_float(v)
          when :double then w.write_double(v)
          when :string, :bytes then w.write_bytes(v.b)
          end
        end

        # @param type [Schema::Message]
        # @param bytes [String]
        # @param lookup [#call, nil] (extendee full name, number) to an extension {Schema::Field}
        # @param keep_unknown [Boolean] keep unknown fields (options messages) or drop them
        # @return [Hash]
        def decode(type, bytes, lookup, keep_unknown:)
          r = Wire::Reader.new(bytes)
          read(r, type, lookup, keep_unknown, nil)
        end

        # @return [Boolean] whether any options in the hash hold unknown fields
        def unknown?(value)
          case value
          when Hash then value.key?(:__unknown_fields) || value.each_value.any? { |v| unknown?(v) }
          when Array then value.any? { |v| unknown?(v) }
          else false
          end
        end

        def read(r, type, lookup, keep_unknown, end_group)
          h = {}
          chunks = nil
          until r.eof?
            item_start = r.pos
            number, wire_type = r.read_tag
            break if end_group && wire_type == Wire::END_GROUP && number == end_group
            if number == 1 && wire_type == Wire::START_GROUP && type.message_set_wire_format?
              read_set_item(r, h, type, lookup, item_start)
              next
            end
            field = type.fields_by_number[number]
            field ||= lookup&.call(type.full_name, number) if type.extension_number?(number)
            if field.nil? || !compatible?(field, wire_type)
              start = r.pos
              r.skip_field(number, wire_type)
              next unless keep_unknown
              (h[:__unknown_fields] ||= []) << [number, wire_type, raw(r, start)]
              next
            end
            target = field.extension? ? (h[:__extensions] ||= {}) : h
            key = field.extension? ? field.full_name : field.name.to_sym
            nested_keep = keep_unknown || field.name == "options"
            if field.type == :message || field.type == :group
              body = if field.type == :group
                start = r.pos
                r.skip_group(number)
                group_body(r, start, number)
              else
                r.read_bytes
              end
              if field.repeated?
                (target[key] ||= []) << decode(field.message_type, body, lookup, keep_unknown: nested_keep)
              else
                chunks ||= {}
                (chunks[[target, key, field]] ||= +"".b) << body
              end
            elsif field.repeated?
              list = (target[key] ||= [])
              if wire_type == Wire::LENGTH_DELIMITED && field.packable?
                packed = Wire::Reader.new(r.read_bytes)
                list << read_value(packed, field) until packed.eof?
              else
                list << read_value(r, field)
              end
            else
              target[key] = read_value(r, field)
            end
          end
          chunks&.each do |(target, key, field), body|
            nested_keep = keep_unknown || field.name == "options"
            target[key] = decode(field.message_type, body, lookup, keep_unknown: nested_keep)
          end
          h
        end

        # One MessageSet item; kept whole as an unknown group when its
        # extension is not known
        def read_set_item(r, h, type, lookup, item_start)
          body_start = r.pos
          r.skip_group(1)
          item = Wire::Reader.new(group_body(r, body_start, 1))
          type_id = message = nil
          until item.eof?
            n, wt = item.read_tag
            if n == 2 && wt == Wire::VARINT
              type_id = item.read_varint
            elsif n == 3 && wt == Wire::LENGTH_DELIMITED
              message = item.read_bytes
            else
              item.skip_field(n, wt)
            end
          end
          field = type_id && message && lookup&.call(type.full_name, type_id)
          if field && field.type == :message
            exts = (h[:__extensions] ||= {})
            decoded = decode(field.message_type, message, lookup, keep_unknown: true)
            exts[field.full_name] = decoded
          else
            (h[:__unknown_fields] ||= []) << [1, Wire::START_GROUP, raw(r, body_start)]
          end
          item_start
        end

        def compatible?(field, wire_type)
          return true if wire_type == field.wire_type
          wire_type == Wire::LENGTH_DELIMITED && field.packable?
        end

        def raw(r, start)
          r.buffer.byteslice(start, r.pos - start).b
        end

        def group_body(r, start, number)
          all = raw(r, start)
          all.byteslice(0, all.bytesize - Wire.varint_size(Wire.tag(number, Wire::END_GROUP)))
        end

        def read_value(r, field)
          case field.type
          when :int32 then r.read_int32
          when :int64 then r.read_int64
          when :uint32 then r.read_uint32
          when :uint64 then r.read_varint
          when :sint32 then r.read_sint32
          when :sint64 then r.read_sint64
          when :bool then r.read_varint != 0
          when :enum
            number = r.read_int32
            field.enum_type.values_by_number[number]&.name&.to_sym || number
          when :fixed32 then r.read_fixed32
          when :fixed64 then r.read_fixed64
          when :sfixed32 then r.read_sfixed32
          when :sfixed64 then r.read_sfixed64
          when :float then r.read_float
          when :double then r.read_double
          when :string then r.read_bytes.force_encoding(Encoding::UTF_8)
          when :bytes then r.read_bytes.b
          end
        end
      end
    end

    class File
      # This file as a `google.protobuf.FileDescriptorProto` of the bootstrap
      # classes; custom options are encoded as extension bytes, which the
      # message keeps as unknown fields.
      # @param pool [Pool, nil] consulted for extensions the file's imports do not define
      #   (those of `import option` files)
      # @return [Protostar::Google::Protobuf::FileDescriptorProto]
      def to_proto(pool: nil)
        Proto.types::FileDescriptorProto.decode(serialize(pool: pool))
      end

      # @param pool [Pool, nil] see {#to_proto}
      # @param source_info [Boolean] include `source_code_info` when the file has it
      # @return [String] the serialized FileDescriptorProto, byte for byte what protoc writes
      def serialize(pool: nil, source_info: true)
        hash = to_h
        hash.delete(:source_code_info) unless source_info
        Proto::HashCodec.encode(Proto.schema(:FileDescriptorProto), hash, extension_finder(pool))
      end

      # @api private
      # @return [#call] extension full name to its {Field}, looked up in this
      #   file, its imports, theirs, and then the pool
      def extension_finder(pool = nil)
        files = []
        queue = [self]
        seen = {}
        until queue.empty?
          f = queue.shift
          next if seen[f.name]
          seen[f.name] = true
          files << f
          queue.concat(f.dependency_files)
        end
        lambda do |name|
          files.each do |f|
            found = f.find_extension(name)
            return found if found
          end
          found = pool&.find_symbol(name)
          found if found.is_a?(Field) && found.extension?
        end
      end
    end

    class Builder
      # Builds a file from a `google.protobuf.FileDescriptorProto` message (or
      # its bytes), as a plugin receives them. Extension bytes in options are
      # decoded into `:__extensions` by the extensions the pool (or the file
      # itself) defines; others stay under `:__unknown_fields`.
      # @param message [Protostar::Google::Protobuf::FileDescriptorProto, String]
      # @param pool [Pool] where dependencies and extensions are looked up; the file is not added
      # @return [File]
      def self.from_proto(message, pool:)
        bytes = message.is_a?(String) ? message : message.encode
        Proto.build(bytes, pool)
      end
    end

    class Pool
      # Builds and adds a serialized FileDescriptorProto, unless a file of that name is here
      # @return [File]
      def add_serialized_file(bytes)
        Proto.load_file(bytes, self)
      end

      # @see Protostar.load_descriptor_set
      def load_descriptor_set(bytes)
        Protostar.load_descriptor_set(bytes, pool: self)
      end
    end
  end
end
