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
      Schema::Proto.each_file(bytes).map { |file_bytes| pool.add_serialized_file(file_bytes) }
    end
  end

  Pool = Schema::Pool

  module Schema
    # The one place that knows protoc's shape. {File#to_proto} writes a
    # file as the `FileDescriptorProto` message of the bootstrap classes
    # (`Protostar::Google::Protobuf`), as protoc's `FileDescriptor::CopyTo`
    # would; {File.from_proto} reads one back into a draft. Custom options
    # exist as extension bytes inside options messages only here: written by
    # {MessageValue#encode}, read by {MessageValue.decode}.
    module Proto
      # @return [Module] `Protostar::Google::Protobuf`, descriptor.proto's message classes
      def self.types
        require "protostar/google/protobuf/descriptor_pb"
        ::Protostar::Google::Protobuf
      end

      # @param name [Symbol, String] a descriptor.proto message, e.g. :FieldOptions
      # @return [Schema::Message] its descriptor, as the bootstrap defines it
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

      # Descriptors as descriptor.proto messages
      # @api private
      module Writer
        module_function

        def file(file, source_info:, json_names:)
          attrs = {name: file.name}
          attrs[:package] = file.package unless file.package.empty?
          attrs[:dependency] = file.dependencies unless file.dependencies.empty?
          attrs[:public_dependency] = file.public_dependencies unless file.public_dependencies.empty?
          attrs[:weak_dependency] = file.weak_dependencies unless file.weak_dependencies.empty?
          attrs[:option_dependency] = file.option_dependencies unless file.option_dependencies.empty?
          list(attrs, :message_type, file.messages) { |m| message(m, json_names) }
          list(attrs, :enum_type, file.enums) { |e| enum(e) }
          list(attrs, :service, file.services) { |s| service(s) }
          list(attrs, :extension, file.extensions) { |f| field(f, json_names) }
          options(attrs, file)
          attrs[:source_code_info] = source_code_info(file.source_info) if source_info && file.source_info
          attrs[:syntax] = file.proto_syntax if file.proto_syntax
          attrs[:edition] = file.edition if file.edition
          Proto.types::FileDescriptorProto.new(**attrs)
        end

        def message(message, json_names)
          t = Proto.types
          attrs = {name: message.name}
          list(attrs, :field, message.fields) { |f| field(f, json_names) }
          list(attrs, :extension, message.extensions) { |f| field(f, json_names) }
          list(attrs, :nested_type, message.nested_messages) { |m| message(m, json_names) }
          list(attrs, :enum_type, message.nested_enums) { |e| enum(e) }
          list(attrs, :extension_range, message.extension_range_descriptors) do |r|
            range = {start: r.start, end: r.end + 1}
            options(range, r)
            t::DescriptorProto::ExtensionRange.new(**range)
          end
          list(attrs, :oneof_decl, message.oneofs) { |o| oneof(o) }
          options(attrs, message)
          list(attrs, :reserved_range, message.reserved_ranges) do |r|
            t::DescriptorProto::ReservedRange.new(start: r.begin, end: r.end + 1)
          end
          attrs[:reserved_name] = message.reserved_names unless message.reserved_names.empty?
          attrs[:visibility] = Proto.visibility(message.visibility) if message.visibility
          t::DescriptorProto.new(**attrs)
        end

        def field(field, json_names)
          attrs = {name: field.name, number: field.number, label: Field::PROTO_LABELS.fetch(field.declared_label),
                   type: Field::PROTO_TYPES.fetch(field.declared_type)}
          attrs[:type_name] = ".#{field.type_name}" if field.type_name
          attrs[:extendee] = ".#{field.extendee.full_name}" if field.extension?
          attrs[:default_value] = field.raw_default if field.raw_default
          attrs[:oneof_index] = field.oneof.index if field.oneof
          attrs[:json_name] = field.json_name if json_names || field.json_name != Schema.json_name(field.name)
          options(attrs, field)
          attrs[:proto3_optional] = true if field.proto3_optional?
          Proto.types::FieldDescriptorProto.new(**attrs)
        end

        def oneof(oneof)
          attrs = {name: oneof.name}
          options(attrs, oneof)
          Proto.types::OneofDescriptorProto.new(**attrs)
        end

        def enum(enum)
          t = Proto.types
          attrs = {name: enum.name}
          list(attrs, :value, enum.values) { |v| enum_value(v) }
          options(attrs, enum)
          list(attrs, :reserved_range, enum.reserved_ranges) do |r|
            t::EnumDescriptorProto::EnumReservedRange.new(start: r.begin, end: r.end)
          end
          attrs[:reserved_name] = enum.reserved_names unless enum.reserved_names.empty?
          attrs[:visibility] = Proto.visibility(enum.visibility) if enum.visibility
          t::EnumDescriptorProto.new(**attrs)
        end

        def enum_value(value)
          attrs = {name: value.name, number: value.number}
          options(attrs, value)
          Proto.types::EnumValueDescriptorProto.new(**attrs)
        end

        def service(service)
          attrs = {name: service.name}
          list(attrs, :method, service.rpcs) { |m| rpc(m) }
          options(attrs, service)
          Proto.types::ServiceDescriptorProto.new(**attrs)
        end

        def rpc(rpc)
          attrs = {name: rpc.name, input_type: ".#{rpc.input_type.full_name}",
                   output_type: ".#{rpc.output_type.full_name}"}
          options(attrs, rpc)
          attrs[:client_streaming] = true if rpc.client_streaming?
          attrs[:server_streaming] = true if rpc.server_streaming?
          Proto.types::MethodDescriptorProto.new(**attrs)
        end

        def source_code_info(info)
          location = Proto.types::SourceCodeInfo::Location
          locations = info.locations.map do |loc|
            attrs = {path: loc.path, span: loc.span}
            attrs[:leading_comments] = loc.leading_comments if loc.leading_comments
            attrs[:trailing_comments] = loc.trailing_comments if loc.trailing_comments
            attrs[:leading_detached_comments] = loc.leading_detached_comments unless loc.leading_detached_comments.empty?
            location.new(**attrs)
          end
          Proto.types::SourceCodeInfo.new(location: locations)
        end

        def options(attrs, descriptor)
          options = descriptor.options
          attrs[:options] = options.to_proto if options.declared?
        end

        FILE_SOURCE_CODE_INFO = 9 # FileDescriptorProto.source_code_info

        # A serialized FileDescriptorProto with `source_code_info` put in its
        # place among the fields, which are in number order. Thousands of
        # locations are written straight to bytes rather than built as
        # messages first: the same bytes, a quarter of the time.
        def with_source_code_info(bytes, info)
          r = Wire::Reader.new(bytes)
          at = bytes.bytesize
          until r.eof?
            start = r.pos
            number, wire_type = r.read_tag
            if number > FILE_SOURCE_CODE_INFO
              at = start
              break
            end
            r.skip_field(number, wire_type)
          end
          out = bytes.byteslice(0, at)
          w = Wire::Writer.new(out)
          w.write_tag(FILE_SOURCE_CODE_INFO, Wire::LENGTH_DELIMITED)
          w.write_bytes(source_code_info_bytes(info))
          w.flush
          out << bytes.byteslice(at, bytes.bytesize - at)
        end

        # SourceCodeInfo: location = 1; and in Location, path = 1 and span = 2
        # (packed), leading_comments = 3, trailing_comments = 4,
        # leading_detached_comments = 6
        def source_code_info_bytes(info)
          out = "".b
          w = Wire::Writer.new(out)
          loc_bytes = "".b
          info.locations.each do |loc|
            loc_bytes.clear
            lw = Wire::Writer.new(loc_bytes)
            packed(lw, 1, loc.path)
            packed(lw, 2, loc.span)
            string(lw, 3, loc.leading_comments) if loc.leading_comments
            string(lw, 4, loc.trailing_comments) if loc.trailing_comments
            loc.leading_detached_comments.each { |c| string(lw, 6, c) }
            lw.flush
            w.write_tag(1, Wire::LENGTH_DELIMITED)
            w.write_bytes(loc_bytes)
          end
          w.flush
          out
        end

        def packed(w, number, values)
          return if values.empty?
          size = values.sum { |v| Wire.varint_size(v) }
          w.write_tag(number, Wire::LENGTH_DELIMITED)
          w.write_varint(size)
          values.each { |v| w.write_varint(v) }
        end

        def string(w, number, text)
          w.write_tag(number, Wire::LENGTH_DELIMITED)
          w.write_bytes(text.b)
        end

        def list(attrs, key, items, &block)
          attrs[key] = items.map(&block) unless items.empty?
        end
      end

      # A FileDescriptorProto message read into a draft
      # @api private
      class Reader
        def initialize(proto, pool)
          @proto = proto
          @pool = pool
          @options = []
        end

        def call
          p = @proto
          draft = File.draft(p.name, package: (p.package if p.has_package?), syntax: (p.syntax.to_sym if p.has_syntax?),
            edition: (p.edition if p.has_edition?), dependencies: p.dependency.to_a,
            public_dependencies: p.public_dependency.to_a, weak_dependencies: p.weak_dependency.to_a,
            option_dependencies: p.option_dependency.to_a)
          record(draft.descriptor, p)
          draft.source_info = source_info(p.source_code_info) if p.has_source_code_info?
          p.message_type.each { |m| message(draft, m) }
          p.enum_type.each { |e| enum(draft, e) }
          p.extension.each { |f| extension(draft, f) }
          p.service.each do |s|
            service = draft.service(s.name)
            record(service.descriptor, s)
            s["method"].each do |m|
              record(service.rpc(m.name, m.input_type, m.output_type, client_streaming: m.client_streaming,
                server_streaming: m.server_streaming), m)
            end
          end
          draft.link(@pool)
          lookup = extension_lookup(draft.descriptor)
          @options.each do |descriptor, options|
            draft.set_options(descriptor, MessageValue.decode(options.class.descriptor, options.encode, lookup))
          end
          draft.resolve(@pool).freeze!
        end

        private

        def record(descriptor, proto)
          @options << [descriptor, proto.options] if proto.has_options?
        end

        # Extensions from the pool, then those the file defines itself
        def extension_lookup(file)
          own = file.all_extensions.to_h { |e| [[e.extendee.full_name, e.number], e] }
          ->(extendee, number) { @pool.find_extension(extendee, number) || own[[extendee, number]] }
        end

        def message(scope, proto)
          visibility = Proto.visibility_symbol(proto.visibility) if proto.has_visibility?
          draft = scope.message(proto.name, visibility: visibility)
          record(draft.descriptor, proto)
          oneofs = proto.oneof_decl.map do |o|
            oneof = draft.oneof(o.name)
            record(oneof, o)
            oneof
          end
          proto.field.each { |f| field(draft, f, oneofs) }
          proto.nested_type.each { |m| message(draft, m) }
          proto.enum_type.each { |e| enum(draft, e) }
          proto.extension.each { |f| extension(draft, f) }
          proto.extension_range.each { |r| record(draft.extension_range(r.start..(r.end - 1)), r) }
          proto.reserved_range.each { |r| draft.reserved(r.start..(r.end - 1)) }
          draft.reserved(*proto.reserved_name)
        end

        def field(scope, proto, oneofs)
          raise Error, "#{@proto.name}: field #{proto.name} has an extendee" if proto.has_extendee?
          oneof = oneofs[proto.oneof_index] if proto.has_oneof_index?
          raise Error, "#{@proto.name}: #{proto.name} has an invalid oneof_index" if proto.has_oneof_index? && !oneof
          type, type_name, kwargs = field_attributes(proto)
          record(scope.field(proto.name, proto.number, type, type_name, oneof: oneof, **kwargs), proto)
        end

        def extension(scope, proto)
          raise Error, "#{@proto.name}: extension #{proto.name} has no extendee" unless proto.has_extendee?
          type, type_name, kwargs = field_attributes(proto)
          record(scope.extension(proto.name, proto.number, type, type_name, extendee: proto.extendee, **kwargs), proto)
        end

        def field_attributes(proto)
          type = Field::TYPES.fetch(proto.type) if proto.has_type?
          type_name = proto.type_name if proto.has_type_name?
          kwargs = {label: proto.has_label? ? Field::LABELS.fetch(proto.label) : :optional,
                    default: (proto.default_value if proto.has_default_value?),
                    json_name: (proto.json_name if proto.has_json_name?), optional: proto.proto3_optional}
          [type, type_name, kwargs]
        end

        def enum(scope, proto)
          visibility = Proto.visibility_symbol(proto.visibility) if proto.has_visibility?
          draft = scope.enum(proto.name, visibility: visibility)
          record(draft.descriptor, proto)
          proto.value.each { |v| record(draft.value(v.name, v.number), v) }
          proto.reserved_range.each { |r| draft.reserved(r.start..r.end) }
          draft.reserved(*proto.reserved_name)
        end

        def source_info(proto)
          SourceInfo.new(proto.location.map do |loc|
            SourceInfo::Location.new(path: loc.path.to_a, span: loc.span.to_a,
              leading_comments: (loc.leading_comments if loc.has_leading_comments?),
              trailing_comments: (loc.trailing_comments if loc.has_trailing_comments?),
              leading_detached_comments: loc.leading_detached_comments.to_a)
          end)
        end
      end

      # descriptor.proto's SymbolVisibility for {Message#visibility} and {Enum#visibility}
      # @api private
      def self.visibility(symbol)
        (symbol == :local) ? :VISIBILITY_LOCAL : :VISIBILITY_EXPORT
      end

      # @api private
      def self.visibility_symbol(proto)
        Draft.visibility(proto)
      end

      # Message values to and from wire bytes, driven by {Schema::Message}s:
      # fields in number order with extensions among them, unknown fields
      # last; packed repeated fields per features; MessageSet items for
      # `message_set_wire_format` types; proto3 zero values left out.
      # @api private
      module Codec
        module_function

        def encode(type, value)
          entries = []
          value.fields.each do |name, v|
            field = type.fields_by_name[name.to_s] || raise(Error, "#{type.full_name} has no field #{name}")
            entries << [field, v]
          end
          value.extensions.each { |field, v| entries << [field, v] }
          out = "".b
          w = Wire::Writer.new(out)
          entries.sort_by! { |f, _| f.number }
          entries.each do |field, v|
            if field.extension? && type.message_set_wire_format?
              write_set_item(w, field, v)
            else
              write_field(w, field, v)
            end
          end
          w.write_raw(value.unknown_fields) unless value.unknown_fields.empty?
          w.flush
          out
        end

        # A MessageSet item: group 1 holding type_id 2 and message 3
        def write_set_item(w, field, value)
          w.write_tag(1, Wire::START_GROUP)
          w.write_tag(2, Wire::VARINT)
          w.write_varint(field.number)
          w.write_tag(3, Wire::LENGTH_DELIMITED)
          w.write_bytes(encode(field.message_type, value))
          w.write_tag(1, Wire::END_GROUP)
        end

        def write_field(w, field, value)
          if field.repeated?
            return if value.empty?
            if field.packed?
              body = "".b
              inner = Wire::Writer.new(body)
              value.each { |v| write_value(inner, field, v) }
              inner.flush
              w.write_tag(field.number, Wire::LENGTH_DELIMITED)
              w.write_bytes(body)
            else
              value.each { |v| write_one(w, field, v) }
            end
          else
            return if !field.presence? && zero?(field, value)
            write_one(w, field, value)
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

        def write_one(w, field, value)
          case field.type
          when :message
            w.write_tag(field.number, Wire::LENGTH_DELIMITED)
            w.write_bytes(encode(field.message_type, value))
          when :group
            w.write_tag(field.number, Wire::START_GROUP)
            w.write_raw(encode(field.message_type, value))
            w.write_tag(field.number, Wire::END_GROUP)
          else
            w.write_tag(field.number, field.wire_type)
            write_value(w, field, value)
          end
        end

        def write_value(w, field, v)
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

        def decode(type, bytes, lookup)
          read(Wire::Reader.new(bytes), type, lookup)
        end

        def read(r, type, lookup)
          fields = {}
          extensions = {}
          unknown = nil
          chunks = nil
          until r.eof?
            number, wire_type = r.read_tag
            if number == 1 && wire_type == Wire::START_GROUP && type.message_set_wire_format?
              unknown = read_set_item(r, extensions, type, lookup, unknown)
              next
            end
            field = type.fields_by_number[number]
            field ||= lookup&.call(type.full_name, number) if type.extension_number?(number)
            if field.nil? || !compatible?(field, wire_type)
              start = r.pos
              r.skip_field(number, wire_type)
              unknown = (unknown || "".b) << tag_bytes(number, wire_type) << raw(r, start)
              next
            end
            target = field.extension? ? extensions : fields
            key = field.extension? ? field : field.name.to_sym
            if field.type == :message || field.type == :group
              body = if field.type == :group
                start = r.pos
                r.skip_group(number)
                group_body(r, start, number)
              else
                r.read_bytes
              end
              if field.repeated?
                (target[key] ||= []) << decode(field.message_type, body, lookup)
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
            target[key] = decode(field.message_type, body, lookup)
          end
          MessageValue.new(fields, extensions, unknown || MessageValue::EMPTY_BYTES)
        end

        # One MessageSet item; kept whole as an unknown group when its
        # extension is not known
        def read_set_item(r, extensions, type, lookup, unknown)
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
            extensions[field] = decode(field.message_type, message, lookup)
            unknown
          else
            (unknown || "".b) << tag_bytes(1, Wire::START_GROUP) << raw(r, body_start)
          end
        end

        def compatible?(field, wire_type)
          return true if wire_type == field.wire_type
          wire_type == Wire::LENGTH_DELIMITED && field.packable?
        end

        def tag_bytes(number, wire_type)
          out = "".b
          w = Wire::Writer.new(out)
          w.write_tag(number, wire_type)
          w.flush
          out
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

    class MessageValue
      # This value in wire format
      # @param type [Message] the message type it is a value of
      # @return [String] binary
      def encode(type)
        Proto::Codec.encode(type, self)
      end

      # @param type [Message]
      # @param bytes [String]
      # @param extensions [#call, nil] (extendee full name, number) to an extension {Field};
      #   fields it does not know stay in {#unknown_fields}
      # @return [MessageValue]
      def self.decode(type, bytes, extensions = nil)
        Proto::Codec.decode(type, bytes, extensions)
      end
    end

    class Options
      # These options as the descriptor.proto message they are (a
      # `Protostar::Google::Protobuf::FieldOptions`, say), custom options as
      # extension bytes the message keeps as unknown fields
      # @return [Protostar::Message]
      def to_proto
        klass = Proto.types.const_get(type_name.delete_prefix("google.protobuf."))
        klass.decode(encode(klass.descriptor))
      end
    end

    class File
      # This file as a `google.protobuf.FileDescriptorProto` of the bootstrap
      # classes, as protoc's `FileDescriptor::CopyTo` writes it
      # @param source_info [Boolean] include `source_code_info` when the file has it
      # @param default_json_names [Boolean] false leaves out every `json_name` equal to the one
      #   derived from the field name, as protoc's Ruby generator embeds descriptors
      # @return [Protostar::Google::Protobuf::FileDescriptorProto]
      def to_proto(source_info: true, default_json_names: true)
        Proto::Writer.file(self, source_info: source_info, json_names: default_json_names)
      end

      # @param (see #to_proto)
      # @return [String] the serialized FileDescriptorProto, byte for byte what protoc writes
      def serialize(source_info: true, default_json_names: true)
        bytes = to_proto(source_info: false, default_json_names: default_json_names).encode
        return bytes unless source_info && @source_info
        Proto::Writer.with_source_code_info(bytes, @source_info)
      end

      # Builds a file from a `google.protobuf.FileDescriptorProto` message (or
      # its bytes), as a plugin receives them. Extension bytes in options are
      # decoded by the extensions the pool (or the file itself) defines;
      # others stay {Options#unknown_fields}.
      # @param proto [Protostar::Google::Protobuf::FileDescriptorProto, String]
      # @param pool [Pool] where dependencies and extensions are looked up; the file is not added
      # @return [File]
      def self.from_proto(proto, pool:)
        proto = Proto.types::FileDescriptorProto.decode(proto) if proto.is_a?(String)
        Proto::Reader.new(proto, pool).call
      end
    end

    class Message
      # @param default_json_names [Boolean] see {File#to_proto}
      # @return [Protostar::Google::Protobuf::DescriptorProto]
      def to_proto(default_json_names: true)
        Proto::Writer.message(self, default_json_names)
      end
    end

    class Field
      # @param default_json_names [Boolean] see {File#to_proto}
      # @return [Protostar::Google::Protobuf::FieldDescriptorProto]
      def to_proto(default_json_names: true)
        Proto::Writer.field(self, default_json_names)
      end
    end

    class Oneof
      # @return [Protostar::Google::Protobuf::OneofDescriptorProto]
      def to_proto
        Proto::Writer.oneof(self)
      end
    end

    class Enum
      # @return [Protostar::Google::Protobuf::EnumDescriptorProto]
      def to_proto
        Proto::Writer.enum(self)
      end
    end

    class EnumValue
      # @return [Protostar::Google::Protobuf::EnumValueDescriptorProto]
      def to_proto
        Proto::Writer.enum_value(self)
      end
    end

    class Service
      # @return [Protostar::Google::Protobuf::ServiceDescriptorProto]
      def to_proto
        Proto::Writer.service(self)
      end
    end

    class Method
      # @return [Protostar::Google::Protobuf::MethodDescriptorProto]
      def to_proto
        Proto::Writer.rpc(self)
      end
    end

    class Descriptor
      # {#to_proto} as a Hash, for reading; nothing builds from it
      # @return [Hash]
      def to_h
        to_proto.to_h
      end
    end

    class Pool
      # Builds and adds a serialized FileDescriptorProto, unless a file of that name is here
      # @return [File]
      def add_serialized_file(bytes)
        proto = Proto.types::FileDescriptorProto.decode(bytes)
        file(proto.name) || add(File.from_proto(proto, pool: self))
      end

      # @see Protostar.load_descriptor_set
      def load_descriptor_set(bytes)
        Protostar.load_descriptor_set(bytes, pool: self)
      end
    end
  end
end
