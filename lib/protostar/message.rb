# frozen_string_literal: true

module Protostar
  # The base class of every message class. Subclasses are made by
  # {Types.define} from a {Schema::Message}; they get one reader and writer
  # per field, `has_` and `clear_` for fields with presence, and `which_` for
  # each oneof.
  #
  #   person = Person.new(name: "Ada", ids: [1, 2])
  #   bytes = person.encode
  #   Person.decode(bytes) == person # => true
  #
  # Values are kept in one Array per message, a slot per field. Singular
  # fields with presence hold nil when unset; fields without presence hold
  # their value, the default included. Repeated fields hold an Array and maps
  # a Hash, both allocated on first access.
  class Message
    EMPTY_ARRAY = [].freeze
    EMPTY_HASH = {}.freeze

    class << self
      # @return [Schema::Message]
      attr_reader :descriptor

      # @api private
      attr_reader :__fields, :__by_number, :__by_name, :__template, :__oneofs, :__required

      # @param bytes [String, IO::Buffer] never mutated
      # @param recursion_limit [Integer] how deep messages may nest
      # @param frozen [Boolean] return a deep-frozen, Ractor-shareable message
      # @return [Message]
      # @raise [DecodeError]
      def decode(bytes, recursion_limit: Codec::Decoder::RECURSION_LIMIT, frozen: false)
        Codec::Decoder.decode(self, bytes, recursion_limit: recursion_limit, frozen: frozen)
      end

      # Reads one message prefixed by its varint length
      # @param source [String, IO::Buffer, #getbyte and #read] a String is read
      #   from its start; an IO from its current position, leaving it after the message
      # @return [Message, nil] nil when an IO is at its end
      # @raise [DecodeError]
      def decode_delimited(source, **options)
        Codec::Decoder.decode_delimited(self, source, **options)
      end

      # @param message [Message] an instance of this class
      # @return [String] binary
      def encode(message)
        unless message.instance_of?(self)
          raise Protostar::TypeError, "#{descriptor.full_name}.encode expects a #{descriptor.full_name}, got #{message.class}"
        end
        message.encode
      end

      # @param json [String]
      # @param options [Hash] see {JSON.decode}
      # @return [Message]
      # @raise [JSON::ParseError]
      def decode_json(json, **options)
        JSON.decode(self, json, **options)
      end

      # @param message [Message] an instance of this class
      # @param options [Hash] see {JSON.encode}
      # @return [String]
      def encode_json(message, **options)
        unless message.instance_of?(self)
          raise Protostar::TypeError, "#{descriptor.full_name}.encode_json expects a #{descriptor.full_name}, got #{message.class}"
        end
        JSON.encode(message, **options)
      end

      # @return [Message] a new message with `b` merged into a copy of `a`
      def merge(a, b)
        a.dup.merge!(b)
      end

      # @return [Message] a message with every field unset, bypassing argument parsing
      # @api private
      def __empty
        m = allocate
        m.__reset
        m
      end

      # @api private
      def __define(descriptor:, fields:, oneofs:)
        @descriptor = descriptor
        @__fields = fields
        @__by_number = fields.to_h { |f| [f.number, f] }
        @__by_name = fields.each_with_object({}) { |f, h| h[f.name] = h[f.symbol] = f }
        @__template = fields.map { |f| (f.presence || f.repeated || f.map) ? nil : f.default }
        @__oneofs = oneofs
        @__required = fields.select(&:required)
        [@__fields, @__by_number, @__by_name, @__template, @__oneofs, @__required].each do |o|
          Ractor.make_shareable(o)
        end
        self
      end

      def inspect
        name || "#<Class #{descriptor ? descriptor.full_name : "Protostar::Message"}>"
      end
    end

    # @param hash [Hash, nil] field names (Symbols or Strings) to values
    # @param fields [Hash] the same, as keywords
    # @raise [ArgumentError] for a name that is not a field
    # @raise [Protostar::TypeError] for a value the field cannot hold
    def initialize(hash = nil, **fields)
      klass = self.class
      raise NotImplementedError, "#{klass} is abstract; define message classes with Protostar::Types" unless klass.__fields
      @values = klass.__template.dup
      @unknown = nil
      __assign(hash) if hash
      __assign(fields) unless fields.empty?
    end

    # @param name [String, Symbol]
    # @return [Object] what the field's reader returns
    # @raise [ArgumentError] when there is no such field
    def [](name)
      __get(__info(name))
    end

    # @param name [String, Symbol]
    # @raise [ArgumentError] when there is no such field
    def []=(name, value)
      __set(__info(name).index, value)
    end

    # @return [Array<UnknownField>] frozen, in the order they were read
    def unknown_fields
      @unknown || EMPTY_ARRAY
    end

    # @return [String] binary
    def encode
      Codec::Encoder.encode(self)
    end
    alias_method :to_proto, :encode

    # Writes the message to an IO without building the whole encoding in memory
    # @return [IO] the IO given
    def encode_to(io)
      Codec::Encoder.encode_to(self, io)
      io
    end

    # @param options [Hash] see {JSON.encode}
    # @return [String] the message as proto3 JSON
    def to_json(_state = nil, **options)
      JSON.encode(self, **options)
    end

    # @param options [Hash] see {Text.print}
    # @return [String] the message in protoc's text format
    def to_text(**options)
      Text.print(self, **options)
    end

    # The message prefixed by its varint length
    # @param io [IO, nil] where to write it
    # @return [String, IO] the bytes when no IO is given, otherwise the IO
    def encode_delimited(io = nil)
      Codec::Encoder.encode_delimited(self, io)
    end

    # @return [Hash] Symbol keys, every field that is set or not at its
    #   default; nested messages as Hashes, enums as Symbols
    def to_h
      __to_h
    end

    # {#to_h} as Message defines it; well-known types replace to_h (a Struct
    # gives a plain Hash), but nested messages always convert field by field
    # @api private
    def __to_h
      h = {}
      values = @values
      self.class.__fields.each do |info|
        v = values[info.index]
        next if v.nil?
        if info.map
          next if v.empty?
          h[info.symbol] = info.value.message? ? v.transform_values(&:__to_h) : v.dup
        elsif info.repeated
          next if v.empty?
          h[info.symbol] = info.message? ? v.map(&:__to_h) : v.dup
        elsif info.message?
          h[info.symbol] = v.__to_h
        elsif info.presence || !info.zero?(v)
          h[info.symbol] = v
        end
      end
      h
    end

    # Same class and same field values. Unknown fields are ignored, and NaN
    # equals NaN in float and double fields, as protoc's MessageDifferencer has it.
    def ==(other)
      return other == self if other.is_a?(View)
      return true if equal?(other)
      return false unless other.instance_of?(self.class)
      mine = @values
      theirs = other.__values
      self.class.__fields.each do |info|
        i = info.index
        return false unless Message.__equal_values?(info, mine[i], theirs[i])
      end
      true
    end
    alias_method :eql?, :==

    def hash
      h = [self.class]
      self.class.__fields.each { |info| h << Message.__hash_value(info, @values[info.index]) }
      h.hash
    end

    # Deep copy; the copy is not frozen
    def initialize_copy(source)
      super
      @values = @values.map { |v| Message.__copy_value(v) }
      @unknown = @unknown&.dup&.freeze
    end

    # Deep copy, frozen when the original is (or when asked)
    def clone(freeze: nil)
      copy = dup
      copy.freeze if freeze || (freeze.nil? && frozen?)
      copy
    end

    # Freezes the message and everything it holds, after which it is Ractor.shareable?
    # @return [self]
    def freeze
      return self if frozen?
      @values.each do |v|
        case v
        when Message then v.freeze
        when Array then v.each(&:freeze).freeze
        when Hash then v.each_value(&:freeze).freeze
        end
      end
      @values.freeze
      @unknown&.freeze
      super
    end

    # Merges `other` into this message: singular fields set in `other`
    # replace ours, messages merge recursively, repeated fields append, maps
    # overwrite by key, unknown fields append.
    # @return [self]
    def merge!(other)
      unless other.instance_of?(self.class)
        raise Protostar::TypeError, "cannot merge a #{other.class} into a #{self.class.descriptor.full_name}"
      end
      __check_frozen
      theirs = other.__values
      self.class.__fields.each do |info|
        i = info.index
        v = theirs[i]
        next if v.nil?
        if info.map
          next if v.empty?
          (@values[i] ||= {}).merge!(info.value.message? ? v.transform_values(&:dup) : v)
        elsif info.repeated
          next if v.empty?
          (@values[i] ||= []).concat(info.message? ? v.map(&:dup) : v)
        elsif info.message?
          mine = @values[i]
          if mine.nil?
            __clear_siblings(info)
            @values[i] = v.dup
          else
            mine = @values[i] = mine.dup if mine.frozen?
            mine.merge!(v)
          end
        elsif info.presence || !info.zero?(v)
          __clear_siblings(info)
          @values[i] = v
        end
      end
      @unknown = ((@unknown || EMPTY_ARRAY) + other.unknown_fields).freeze unless other.unknown_fields.empty?
      self
    end

    # Unsets every field and drops unknown fields
    # @return [self]
    def clear!
      __check_frozen
      __reset
      self
    end

    # @return [Boolean] whether every required field is set, here and in every nested message
    def initialized?
      self.class.__required.each { |info| return false if @values[info.index].nil? }
      self.class.__fields.each do |info|
        v = @values[info.index]
        next if v.nil?
        if info.map
          next unless info.value.message?
          v.each_value { |m| return false unless m.initialized? }
        elsif info.message?
          if info.repeated
            v.each { |m| return false unless m.initialized? }
          else
            return false unless v.initialized?
          end
        end
      end
      true
    end

    def inspect
      parts = []
      self.class.__fields.each do |info|
        v = @values[info.index]
        next if v.nil?
        next if (info.repeated || info.map) && v.empty?
        next if !info.presence && !info.repeated && !info.map && info.zero?(v)
        parts << "#{info.name}: #{v.inspect}"
      end
      name = self.class.descriptor.full_name
      parts.empty? ? "#<#{name}>" : "#<#{name} #{parts.join(", ")}>"
    end
    alias_method :to_s, :inspect

    def pretty_print(q)
      q.text(inspect)
    end

    # @api private
    def __values
      @values
    end

    # @api private
    def __reset
      @values = self.class.__template.dup
      @unknown = nil
    end

    # Appends an unknown field; the decoder's way in
    # @api private
    def __add_unknown(field)
      u = @unknown
      if u.nil?
        @unknown = [field]
      elsif u.frozen?
        @unknown = [*u, field]
      else
        u << field
      end
    end

    # @api private
    def __seal_unknown
      @unknown&.freeze
    end

    # @api private
    def __set(index, value)
      __check_frozen
      info = self.class.__fields[index]
      if value.nil?
        @values[index] = (info.presence || info.repeated || info.map) ? nil : info.default
      else
        value = Coercion.field(info, value)
        __clear_siblings(info)
        @values[index] = value
      end
    end

    # @api private
    def __clear(index)
      __check_frozen
      @values[index] = nil
    end

    # The stored Array or Hash of a repeated or map field, made on first use
    # @api private
    def __container(index)
      info = self.class.__fields[index]
      if frozen?
        info.map ? EMPTY_HASH : EMPTY_ARRAY
      else
        @values[index] = info.map ? {} : []
      end
    end

    # @api private
    def __get(info)
      v = @values[info.index]
      if info.repeated || info.map
        v || __container(info.index)
      elsif v.nil?
        info.default
      else
        v
      end
    end

    # @api private
    def self.__equal_values?(info, a, b)
      if info.map
        a ||= EMPTY_HASH
        b ||= EMPTY_HASH
        return a == b unless float_kind?(info.value.kind)
        a.size == b.size && a.all? { |k, v| b.key?(k) && float_equal?(v, b[k]) }
      elsif info.repeated
        a ||= EMPTY_ARRAY
        b ||= EMPTY_ARRAY
        return a == b unless float_kind?(info.kind)
        a.size == b.size && a.each_index.all? { |i| float_equal?(a[i], b[i]) }
      elsif float_kind?(info.kind)
        float_equal?(a, b)
      else
        a == b
      end
    end

    # @api private
    def self.__hash_value(info, v)
      if info.map
        return nil if v.nil? || v.empty?
        float_kind?(info.value.kind) ? v.transform_values { |f| hashable_float(f) } : v
      elsif info.repeated
        return nil if v.nil? || v.empty?
        float_kind?(info.kind) ? v.map { |f| hashable_float(f) } : v
      elsif float_kind?(info.kind)
        hashable_float(v)
      else
        v
      end
    end

    # @api private
    def self.__copy_value(v)
      case v
      when Message then v.dup
      when Array then v.map { |e| e.is_a?(Message) ? e.dup : e }
      when Hash then v.transform_values { |e| e.is_a?(Message) ? e.dup : e }
      else v
      end
    end

    def self.float_kind?(kind)
      kind == FieldInfo::DOUBLE || kind == FieldInfo::FLOAT
    end

    def self.float_equal?(a, b)
      a == b || (a.is_a?(Float) && b.is_a?(Float) && a.nan? && b.nan?)
    end

    def self.hashable_float(f)
      (f.is_a?(Float) && f.nan?) ? :nan : f
    end
    private_class_method :float_kind?, :float_equal?, :hashable_float

    private

    def __info(name)
      self.class.__by_name[name] || raise(ArgumentError, "#{self.class.descriptor.full_name} has no field #{name.inspect}")
    end

    def __assign(hash)
      by_name = self.class.__by_name
      hash.each do |key, value|
        info = by_name[key]
        raise ArgumentError, "#{self.class.descriptor.full_name} has no field #{key.inspect}" unless info
        __set(info.index, value)
      end
    end

    def __clear_siblings(info)
      siblings = info.siblings
      siblings&.each { |s| @values[s] = nil }
    end

    def __check_frozen
      raise FrozenError.new("can't modify frozen #{self.class.descriptor.full_name}", receiver: self) if frozen?
    end
  end
end

require_relative "message/field_info"
require_relative "message/coercion"
require_relative "message/accessors"
