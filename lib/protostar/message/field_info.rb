# frozen_string_literal: true

module Protostar
  class Message
    # Everything the runtime and the codec need about one field of a message
    # class, resolved once when the class is defined: the slot it is stored
    # in, its kind as a small Integer to dispatch on, precomputed tag bytes,
    # the classes and enum tables it refers to. Frozen and shareable.
    # @api private
    class FieldInfo
      # Kinds are FieldDescriptorProto.Type numbers
      DOUBLE = 1
      FLOAT = 2
      INT64 = 3
      UINT64 = 4
      INT32 = 5
      FIXED64 = 6
      FIXED32 = 7
      BOOL = 8
      STRING = 9
      GROUP = 10
      MESSAGE = 11
      BYTES = 12
      UINT32 = 13
      ENUM = 14
      SFIXED32 = 15
      SFIXED64 = 16
      SINT32 = 17
      SINT64 = 18

      KINDS = {
        double: DOUBLE, float: FLOAT, int64: INT64, uint64: UINT64, int32: INT32, fixed64: FIXED64,
        fixed32: FIXED32, bool: BOOL, string: STRING, group: GROUP, message: MESSAGE, bytes: BYTES,
        uint32: UINT32, enum: ENUM, sfixed32: SFIXED32, sfixed64: SFIXED64, sint32: SINT32, sint64: SINT64
      }.freeze

      # Byte width and unpack directive of the fixed-width kinds
      FIXED = {
        DOUBLE => [8, "E"], FLOAT => [4, "e"], FIXED64 => [8, "Q<"], FIXED32 => [4, "V"],
        SFIXED32 => [4, "l<"], SFIXED64 => [8, "q<"]
      }.transform_values(&:freeze).freeze

      # @return [Schema::Field]
      attr_reader :descriptor
      # @return [String]
      attr_reader :name
      # @return [Symbol]
      attr_reader :symbol
      # @return [Integer]
      attr_reader :number
      # @return [Integer, nil] the slot in the message's value array; nil for map keys and values
      attr_reader :index
      # @return [Integer] one of the kind constants
      attr_reader :kind
      # @return [Integer] wire type of one unpacked value
      attr_reader :wire_type
      # @return [Boolean]
      attr_reader :repeated, :packed, :packable, :presence, :map, :closed_enum, :utf8_validation, :required
      # @return [Array<Integer>, nil] slots of the other members of the field's real oneof
      attr_reader :siblings
      # @return [Class, nil] for message and group fields
      attr_reader :message_class
      # @return [Module, nil] for enum fields
      attr_reader :enum_module
      # @return [Hash{Integer => Symbol}, nil] enum number to its first name
      attr_reader :enum_names
      # @return [Hash{Symbol => Integer}, nil] every enum name, aliases included, to its number
      attr_reader :enum_numbers
      # @return [Object] the value an unset field reads as
      attr_reader :default
      # @return [String] the tag of one unpacked value, varint-encoded
      attr_reader :tag
      # @return [String, nil] the length-delimited tag, for packable fields
      attr_reader :packed_tag
      # @return [String, nil] the end-group tag, for groups
      attr_reader :end_tag
      # @return [FieldInfo, nil] for map fields
      attr_reader :key, :value

      # @param field [Schema::Field]
      # @param index [Integer, nil]
      # @param classes [#call] resolves a Schema::Message or Schema::Enum to its Class or Module
      def initialize(field, index, classes, siblings: nil)
        @descriptor = field
        @name = field.name
        @symbol = field.name.to_sym
        @number = field.number
        @index = index
        @kind = KINDS.fetch(field.type)
        @wire_type = field.wire_type
        @map = field.map?
        @repeated = field.repeated? && !@map
        @packed = field.packed?
        @packable = field.packable?
        @presence = field.presence?
        @required = field.required?
        @utf8_validation = field.utf8_validation?
        @siblings = siblings
        @tag = Wire.tag_bytes(@number, @wire_type)
        @packed_tag = Wire.tag_bytes(@number, Wire::LENGTH_DELIMITED) if @packable
        @end_tag = Wire.tag_bytes(@number, Wire::END_GROUP) if @kind == GROUP
        if @map
          @key = FieldInfo.new(field.map_key, nil, classes)
          @value = FieldInfo.new(field.map_value, nil, classes)
        elsif field.message_type
          @message_class = classes.call(field.message_type)
        end
        if field.enum_type
          @enum_module = classes.call(field.enum_type)
          @enum_names = @enum_module.__names
          @enum_numbers = @enum_module.__numbers
          @closed_enum = field.enum_type.closed?
        else
          @closed_enum = false
        end
        @default = field.default unless @map || @repeated
        # an enum default may name an alias; values are stored by their first name
        @default = @enum_names[@enum_numbers.fetch(@default)] if @enum_names && @default
      end

      # @return [Boolean] whether the field is a message or group
      def message?
        @kind == MESSAGE || @kind == GROUP
      end

      # @return [Boolean] whether a singular value equals the type's zero
      #   value, so that a field without presence is left out on encode.
      #   Negative zero is not a default, as in protoc.
      def zero?(value)
        case @kind
        when DOUBLE, FLOAT then value == 0 && (1.0 / value) > 0
        when STRING, BYTES then value.empty?
        when BOOL then value == false
        when ENUM then (value.is_a?(Symbol) ? @enum_numbers[value] : value) == 0
        else value == 0
        end
      end

      def inspect
        "#<#{self.class.name} #{@descriptor.full_name} slot=#{@index}>"
      end
    end
  end
end
