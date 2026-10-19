# frozen_string_literal: true

module Protostar
  module Schema
    # A field of a message, or an extension
    class Field < Descriptor
      # FieldDescriptorProto.Type names to the short type symbols
      TYPES = {
        TYPE_DOUBLE: :double, TYPE_FLOAT: :float, TYPE_INT64: :int64, TYPE_UINT64: :uint64,
        TYPE_INT32: :int32, TYPE_FIXED64: :fixed64, TYPE_FIXED32: :fixed32, TYPE_BOOL: :bool,
        TYPE_STRING: :string, TYPE_GROUP: :group, TYPE_MESSAGE: :message, TYPE_BYTES: :bytes,
        TYPE_UINT32: :uint32, TYPE_ENUM: :enum, TYPE_SFIXED32: :sfixed32, TYPE_SFIXED64: :sfixed64,
        TYPE_SINT32: :sint32, TYPE_SINT64: :sint64
      }.freeze

      # FieldDescriptorProto.Label names to the short label symbols
      LABELS = {LABEL_OPTIONAL: :optional, LABEL_REQUIRED: :required, LABEL_REPEATED: :repeated}.freeze

      PROTO_TYPES = TYPES.invert.freeze # :nodoc:
      PROTO_LABELS = LABELS.invert.freeze # :nodoc:

      # Wire type of a single, unpacked value of each type
      WIRE_TYPES = {
        double: 1, float: 5, int64: 0, uint64: 0, int32: 0, fixed64: 1, fixed32: 5, bool: 0,
        string: 2, group: 3, message: 2, bytes: 2, uint32: 0, enum: 0, sfixed32: 5, sfixed64: 1,
        sint32: 0, sint64: 0
      }.freeze

      # The implicit default of each scalar type
      ZERO = {
        double: 0.0, float: 0.0, int64: 0, uint64: 0, int32: 0, fixed64: 0, fixed32: 0, bool: false,
        string: "".encode(Encoding::UTF_8).freeze, bytes: "".b.freeze, uint32: 0, sfixed32: 0,
        sfixed64: 0, sint32: 0, sint64: 0
      }.freeze

      UNPACKABLE = %i[string bytes message group].freeze

      attr_reader :number #: Integer
      # :optional, :required or :repeated, with editions
      # `LEGACY_REQUIRED` presence reported as :required.
      attr_reader :label #: Symbol
      # :int32, :string, :message, ... with editions
      # `DELIMITED` message fields reported as :group, as protoc does.
      attr_reader :type #: Symbol
      # Full name of the message or enum type, no leading dot.
      attr_reader :type_name #: String?
      attr_reader :message_type #: Message?
      attr_reader :enum_type #: Enum?
      # The declared default parsed to a Ruby value
      # (Integer, Float, true/false, String, binary String, or Symbol for enums).
      attr_reader :default_value #: untyped
      # #default_value, or the type's implicit default:
      # zero, false, an empty String, the first value's name for an enum, nil for messages.
      # For repeated fields this is the default of a single element.
      attr_reader :default #: untyped
      attr_reader :json_name #: String
      # The containing oneof, synthetic ones included.
      attr_reader :oneof #: Oneof?
      # For an extension, the extended message.
      attr_reader :extendee #: Message?
      # The message holding the field; for an extension the
      # message it was declared in, or nil when declared at file level.
      attr_reader :containing_message #: Message?
      attr_reader :file #: File

      def initialize(name:, full_name:, number:, label:, type:, type_name:, extendee_name:, raw_default:, json_name:, # :nodoc:
        proto3_optional:, extension:, containing_message:, file:, index:)
        @name = name
        @full_name = full_name
        @number = number
        @declared_label = label
        @declared_type = type
        @label = label
        @type = type
        @type_name = type_name
        @extendee_name = extendee_name
        @raw_default = raw_default
        @json_name = json_name
        @proto3_optional = proto3_optional
        @extension = extension
        @containing_message = containing_message
        @file = file
        @index = index
      end

      # :stopdoc:
      # The default as protoc stores it in `default_value`.
      attr_reader :raw_default #: String?
      # The extendee as written, until it is resolved.
      attr_reader :extendee_name #: String?
      # The label as declared: :repeated, :optional or :required,
      # before editions features turn `LEGACY_REQUIRED` into :required.
      attr_reader :declared_label #: Symbol?
      # The type as declared, before editions features turn
      # `DELIMITED` message fields into :group; nil while a type name is unresolved.
      attr_reader :declared_type #: Symbol?
      # :startdoc:

      #: () -> bool
      def proto3_optional?
        @proto3_optional
      end

      #: () -> bool
      def extension?
        @extension
      end

      # Returns the containing oneof unless it is synthetic.
      #: () -> Oneof?
      def real_oneof
        @oneof unless @oneof.nil? || @oneof.synthetic?
      end

      #: () -> bool
      def repeated?
        @label == :repeated
      end

      #: () -> bool
      def required?
        @label == :required
      end

      #: () -> bool
      def optional?
        @label == :optional
      end

      # Returns a `map<K, V>` field: repeated, of a map entry message type.
      #: () -> bool
      def map?
        @label == :repeated && !@message_type.nil? && @message_type.map_entry?
      end

      # Returns the key field of a map field's entry.
      #: () -> Field?
      def map_key
        @message_type.fields_by_number[1] if map?
      end

      # Returns the value field of a map field's entry.
      #: () -> Field?
      def map_value
        @message_type.fields_by_number[2] if map?
      end

      # Returns not a message or group; enums count as scalars.
      #: () -> bool
      def scalar?
        @type != :message && @type != :group
      end

      # Returns repeated and of a type that can be packed.
      #: () -> bool
      def packable?
        @label == :repeated && !UNPACKABLE.include?(@type)
      end

      # Returns whether repeated values are written packed. Resolved
      # through features: proto2 defaults to expanded, proto3 to packed, editions
      # follow `repeated_field_encoding`, and a legacy `packed` option wins.
      #: () -> bool
      def packed?
        packable? && @features.repeated_field_encoding == :PACKED
      end

      # Returns explicit presence (has-bits): singular fields that are
      # messages, extensions, oneof members, or not `IMPLICIT` by features.
      #: () -> bool
      def presence?
        return false if @label == :repeated
        @type == :message || @type == :group || @extension || !@oneof.nil? ||
          @features.field_presence != :IMPLICIT
      end

      # Returns group, or editions `message_encoding = DELIMITED`.
      #: () -> bool
      def delimited?
        @type == :group
      end

      # Returns the wire type of one unpacked value.
      #: () -> Integer
      def wire_type
        WIRE_TYPES.fetch(@type)
      end

      # Returns whether string values must be valid UTF-8 when parsed.
      #: () -> bool
      def utf8_validation?
        @type == :string && @features.utf8_validation == :VERIFY
      end

      # - `default_json_names`: see File#to_proto
      #: (?default_json_names: bool) -> Protostar::Google::Protobuf::FieldDescriptorProto
      def to_proto(default_json_names: true)
        Proto::Writer.field(self, default_json_names)
      end
    end
  end
end
