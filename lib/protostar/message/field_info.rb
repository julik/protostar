# frozen_string_literal: true

module Protostar
  class Message
    # Everything the runtime and the codec need about one field of a message
    # class, resolved once when the class is defined: the slot it is stored
    # in, its kind as a small Integer to dispatch on, precomputed tag bytes,
    # the classes and enum tables it refers to. Frozen and shareable.
    class FieldInfo # :nodoc: all
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

      attr_reader :descriptor #: Schema::Field
      attr_reader :name #: String
      attr_reader :symbol #: Symbol
      attr_reader :number #: Integer
      # The field's slot, in declaration order; nil for map keys and values.
      attr_reader :index #: Integer?
      # The instance variable holding the slot, `@_<index>`.
      attr_reader :ivar #: String?
      # One of the kind constants.
      attr_reader :kind #: Integer
      # Wire type of one unpacked value.
      attr_reader :wire_type #: Integer
      attr_reader :repeated, :packed, :packable, :presence, :map, :closed_enum, :utf8_validation, :required #: bool
      # Slots of the other members of the field's real oneof.
      attr_reader :siblings #: Array[Integer]?
      # For message and group fields.
      attr_reader :message_class #: Class?
      # For enum fields.
      attr_reader :enum_module #: Module?
      # Enum number to its first name.
      attr_reader :enum_names #: Hash[Integer, Symbol]?
      # Every enum name, aliases included, to its number.
      attr_reader :enum_numbers #: Hash[Symbol, Integer]?
      # The value an unset field reads as.
      attr_reader :default #: untyped
      # The tag of one unpacked value, varint-encoded.
      attr_reader :tag #: String
      # The length-delimited tag, for packable fields.
      attr_reader :packed_tag #: String?
      # The end-group tag, for groups.
      attr_reader :end_tag #: String?
      # For map fields.
      attr_reader :key, :value #: FieldInfo?

      # - `classes`: resolves a Schema::Message or Schema::Enum to its Class or Module
      # - `open_enums`: treat a closed enum as open
      #: (Schema::Field field, Integer? index, untyped classes, ?siblings: untyped, ?open_enums: bool) -> void
      def initialize(field, index, classes, siblings: nil, open_enums: false)
        @descriptor = field
        @name = field.name
        @symbol = field.name.to_sym
        @number = field.number
        @index = index
        @ivar = "@_#{index}".freeze if index
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
          @value = FieldInfo.new(field.map_value, nil, classes, open_enums: open_enums)
        elsif field.message_type
          @message_class = classes.call(field.message_type)
        end
        if field.enum_type
          @enum_module = classes.call(field.enum_type)
          @enum_names = @enum_module.__names
          @enum_numbers = @enum_module.__numbers
          @closed_enum = !open_enums && field.enum_type.closed?
        else
          @closed_enum = false
        end
        @default = field.default unless @map || @repeated
        # an enum default may name an alias; values are stored by their first name
        @default = @enum_names[@enum_numbers.fetch(@default)] if @enum_names && @default
      end

      # Returns whether the field is a message or group.
      #: () -> bool
      def message?
        @kind == MESSAGE || @kind == GROUP
      end

      # Returns whether a singular value equals the type's zero
      # value, so that a field without presence is left out on encode.
      # Negative zero is not a default, as in protoc.
      #: (untyped value) -> bool
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
