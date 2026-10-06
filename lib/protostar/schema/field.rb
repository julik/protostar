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

      # @api private
      PROTO_TYPES = TYPES.invert.freeze
      # @api private
      PROTO_LABELS = LABELS.invert.freeze

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

      # @return [Integer]
      attr_reader :number
      # @return [Symbol] :optional, :required or :repeated, with editions
      #   `LEGACY_REQUIRED` presence reported as :required
      attr_reader :label
      # @return [Symbol] :int32, :string, :message, ... with editions
      #   `DELIMITED` message fields reported as :group, as protoc does
      attr_reader :type
      # @return [String, nil] full name of the message or enum type, no leading dot
      attr_reader :type_name
      # @return [Message, nil]
      attr_reader :message_type
      # @return [Enum, nil]
      attr_reader :enum_type
      # @return [Object, nil] the declared default parsed to a Ruby value
      #   (Integer, Float, true/false, String, binary String, or Symbol for enums)
      attr_reader :default_value
      # @return [Object, nil] {#default_value}, or the type's implicit default:
      #   zero, false, an empty String, the first value's name for an enum, nil for messages.
      #   For repeated fields this is the default of a single element.
      attr_reader :default
      # @return [String]
      attr_reader :json_name
      # @return [Oneof, nil] the containing oneof, synthetic ones included
      attr_reader :oneof
      # @return [Message, nil] for an extension, the extended message
      attr_reader :extendee
      # @return [Message, nil] the message holding the field; for an extension the
      #   message it was declared in, or nil when declared at file level
      attr_reader :containing_message
      # @return [File]
      attr_reader :file

      # @api private
      def initialize(name:, full_name:, number:, label:, type:, type_name:, extendee_name:, raw_default:, json_name:,
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

      # @api private
      # @return [String, nil] the default as protoc stores it in `default_value`
      attr_reader :raw_default
      # @api private
      # @return [String, nil] the extendee as written, until it is resolved
      attr_reader :extendee_name
      # @api private
      # @return [Symbol, nil] the label as declared: :repeated, :optional or :required,
      #   before editions features turn `LEGACY_REQUIRED` into :required
      attr_reader :declared_label
      # @api private
      # @return [Symbol, nil] the type as declared, before editions features turn
      #   `DELIMITED` message fields into :group; nil while a type name is unresolved
      attr_reader :declared_type

      # @return [Boolean]
      def proto3_optional?
        @proto3_optional
      end

      # @return [Boolean]
      def extension?
        @extension
      end

      # @return [Oneof, nil] the containing oneof unless it is synthetic
      def real_oneof
        @oneof unless @oneof.nil? || @oneof.synthetic?
      end

      # @return [Boolean]
      def repeated?
        @label == :repeated
      end

      # @return [Boolean]
      def required?
        @label == :required
      end

      # @return [Boolean]
      def optional?
        @label == :optional
      end

      # @return [Boolean] a `map<K, V>` field: repeated, of a map entry message type
      def map?
        @label == :repeated && !@message_type.nil? && @message_type.map_entry?
      end

      # @return [Field, nil] the key field of a map field's entry
      def map_key
        @message_type.fields_by_number[1] if map?
      end

      # @return [Field, nil] the value field of a map field's entry
      def map_value
        @message_type.fields_by_number[2] if map?
      end

      # @return [Boolean] not a message or group; enums count as scalars
      def scalar?
        @type != :message && @type != :group
      end

      # @return [Boolean] repeated and of a type that can be packed
      def packable?
        @label == :repeated && !UNPACKABLE.include?(@type)
      end

      # @return [Boolean] whether repeated values are written packed. Resolved
      #   through features: proto2 defaults to expanded, proto3 to packed, editions
      #   follow `repeated_field_encoding`, and a legacy `packed` option wins.
      def packed?
        packable? && @features.repeated_field_encoding == :PACKED
      end

      # @return [Boolean] explicit presence (has-bits): singular fields that are
      #   messages, extensions, oneof members, or not `IMPLICIT` by features
      def presence?
        return false if @label == :repeated
        @type == :message || @type == :group || @extension || !@oneof.nil? ||
          @features.field_presence != :IMPLICIT
      end

      # @return [Boolean] group, or editions `message_encoding = DELIMITED`
      def delimited?
        @type == :group
      end

      # @return [Integer] the wire type of one unpacked value
      def wire_type
        WIRE_TYPES.fetch(@type)
      end

      # @return [Boolean] whether string values must be valid UTF-8 when parsed
      def utf8_validation?
        @type == :string && @features.utf8_validation == :VERIFY
      end

      # @param default_json_names [Boolean] see {File#to_proto}
      # @return [Protostar::Google::Protobuf::FieldDescriptorProto]
      def to_proto(default_json_names: true)
        Proto::Writer.field(self, default_json_names)
      end
    end
  end
end
