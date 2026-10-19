# frozen_string_literal: true

module Protostar
  # The base class of every message class. Subclasses are made by
  # Types.define from a Schema::Message; they get one reader and writer
  # per field, `has_` and `clear_` for fields with presence, and `which_` for
  # each oneof.
  #
  # ```ruby
  # person = Person.new(name: "Ada", ids: [1, 2])
  # bytes = person.encode
  # Person.decode(bytes) == person # => true
  # ```
  #
  # Values are kept in one Array per message, a slot per field. Singular
  # fields with presence hold nil when unset; fields without presence hold
  # their value, the default included. Repeated fields hold an Array and maps
  # a Hash, both allocated on first access.
  class Message
    EMPTY_ARRAY = [].freeze
    EMPTY_HASH = {}.freeze

    # Needed while a class is defined, never after
    autoload :Accessors, ::File.expand_path("message/accessors", __dir__)
    autoload :Reflection, ::File.expand_path("message/reflection", __dir__)

    class << self
      attr_reader :descriptor #: Schema::Message

      # The class's fields by descriptor, name or number.
      attr_reader :reflection #: Reflection

      attr_reader :__fields, :__by_number, :__by_name, :__template, :__oneofs, :__required # :nodoc:

      # - `bytes`: never mutated
      # - `recursion_limit`: how deep messages may nest
      # - `frozen`: return a deep-frozen, Ractor-shareable message
      #
      # Raises DecodeError.
      #: (String | IO::Buffer bytes, ?recursion_limit: Integer, ?frozen: bool) -> instance
      def decode(bytes, recursion_limit: Codec::Decoder::RECURSION_LIMIT, frozen: false)
        Codec::Decoder.decode(self, bytes, recursion_limit: recursion_limit, frozen: frozen)
      end

      # Reads one message prefixed by its varint length
      #
      # - `source`: a String is read
      #   from its start; an IO from its current position, leaving it after the message
      #
      # Returns nil when an IO is at its end.
      # Raises DecodeError.
      #: (String | IO::Buffer | IO source, ?recursion_limit: Integer, ?frozen: bool) -> instance?
      def decode_delimited(source, **options)
        Codec::Decoder.decode_delimited(self, source, **options)
      end

      # - `message`: an instance of this class
      #
      # Returns a binary String.
      #: (instance message) -> String
      def encode(message)
        unless message.instance_of?(self)
          raise Protostar::TypeError, "#{descriptor.full_name}.encode expects a #{descriptor.full_name}, got #{message.class}"
        end
        message.encode
      end

      # - `options`: see JSON.decode
      #
      # Raises JSON::ParseError.
      #: (String json, ?ignore_unknown_fields: bool, ?registry: Types::Registry?) -> instance
      def decode_json(json, **options)
        JSON.decode(self, json, **options)
      end

      # - `message`: an instance of this class
      # - `options`: see JSON.encode
      #: (instance message, **untyped options) -> String
      def encode_json(message, **options)
        unless message.instance_of?(self)
          raise Protostar::TypeError, "#{descriptor.full_name}.encode_json expects a #{descriptor.full_name}, got #{message.class}"
        end
        JSON.encode(message, **options)
      end

      attr_reader :__view_class # :nodoc:

      # Returns the View subclass whose instances read this class's messages.
      #: () -> singleton(View)
      def view_class
        @__view_class || raise(NotImplementedError, "#{self} is abstract; define message classes with Protostar::Types")
      end

      # A read-only view of an encoded message that decodes fields only when read
      #
      # - `bytes`: not copied; must not change while the view is used
      # - `offset`: where the message starts in `bytes`
      # - `length`: its length, by default up to the end of `bytes`
      # - `recursion_limit`: how deep messages may nest
      #
      # Raises DecodeError when the top level of the message is malformed.
      #: (String | IO::Buffer bytes, ?offset: Integer, ?length: Integer?, ?recursion_limit: Integer) -> View
      def view(bytes, offset: 0, length: nil, recursion_limit: Codec::Decoder::RECURSION_LIMIT)
        view_class.__open(bytes, offset, length, recursion_limit)
      end

      # A message made with a Builder block, or with `new` when there is no
      # block. `fields` are written first; the block may set them again (the
      # bytes never leave the process, so overwrites are allowed).
      #
      # ```ruby
      # person = Acme::Person.build(name: "Jane") do |pb|
      #   pb.address { pb.street "x" }
      # end
      # ```
      #
      # - `fields`: field names to values, as #initialize takes them
      #: (?Hash[Symbol | String, untyped]? fields, **untyped) ?{ (Builder pb) -> void } -> instance
      def build(fields = nil, **more, &block)
        return new(fields, **more) unless block
        Builder.message(self, overwrites: true) do |pb|
          pb.merge!(fields) if fields
          pb.merge!(more) unless more.empty?
          block.call(pb)
        end
      end

      # Returns a new message with `b` merged into a copy of `a`.
      #: (instance a, instance b) -> instance
      def merge(a, b)
        a.dup.merge!(b)
      end

      # What a field of this type makes of a value that is neither an
      # instance nor a Hash. The well-known types' mixins override it, so that
      # a Time can be assigned to a Timestamp field.
      #
      # Returns nil when the value cannot become one.
      #: (untyped) -> Message?
      def __coerce(_value) # :nodoc:
        nil
      end

      # Returns a message with every field unset, bypassing argument parsing.
      #: () -> Message
      def __empty # :nodoc:
        m = allocate
        m.__reset
        m
      end

      def __define(descriptor:, fields:, oneofs:) # :nodoc:
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
        @reflection = Ractor.make_shareable(Reflection.new(self, descriptor))
        self
      end

      def inspect
        name || "#<Class #{descriptor ? descriptor.full_name : "Protostar::Message"}>"
      end
    end

    # - `hash`: field names (Symbols or Strings) to values
    # - `fields`: the same, as keywords
    #
    # Raises ArgumentError for a name that is not a field.
    # Raises Protostar::TypeError for a value the field cannot hold.
    #: (?Hash[Symbol | String, untyped]? hash, **untyped fields) -> void
    def initialize(hash = nil, **fields)
      klass = self.class
      raise NotImplementedError, "#{klass} is abstract; define message classes with Protostar::Types" unless klass.__fields
      @values = klass.__template.dup
      @unknown = nil
      __assign(hash) if hash
      __assign(fields) unless fields.empty?
    end

    # Returns what the field's reader returns.
    # Raises ArgumentError when there is no such field.
    #: (String | Symbol name) -> untyped
    def [](name)
      __get(__info(name))
    end

    # Raises ArgumentError when there is no such field.
    #: (String | Symbol name, untyped value) -> untyped
    def []=(name, value)
      __set(__info(name).index, value)
    end

    # Returns them frozen, in the order they were read.
    #: () -> Array[UnknownField]
    def unknown_fields
      @unknown || EMPTY_ARRAY
    end

    # Returns a binary String.
    #: () -> String
    def encode
      Codec::Encoder.encode(self)
    end
    alias_method :to_proto, :encode

    # Writes the message to an IO without building the whole encoding in memory
    #
    # Returns the IO given.
    #: [T] (T io) -> T
    def encode_to(io)
      Codec::Encoder.encode_to(self, io)
      io
    end

    # - `state`: what the stdlib generator passes; its
    #   indentation is honoured, so `JSON.pretty_generate(message)` is indented
    # - `options`: see JSON.encode
    #
    # Returns the message as proto3 JSON.
    #: (?untyped state, **untyped options) -> String
    def to_json(state = nil, **options)
      json = JSON.encode(self, **options)
      state.respond_to?(:object_nl) ? JSON.layout(json, state) : json
    end

    # - `options`: see Text.print
    #
    # Returns the message in protoc's text format.
    #: (**untyped options) -> String
    def to_text(**options)
      Text.print(self, **options)
    end

    # The message prefixed by its varint length
    #
    # - `io`: where to write it
    #
    # Returns the bytes when no IO is given, otherwise the IO.
    #: () -> String
    #: [T] (T io) -> T
    def encode_delimited(io = nil)
      Codec::Encoder.encode_delimited(self, io)
    end

    # Returns Symbol keys, every field that is set or not at its
    # default; nested messages as Hashes, enums as Symbols.
    #: () -> Hash[Symbol, untyped]
    def to_h
      __to_h
    end

    # #to_h as Message defines it; well-known types replace to_h (a Struct
    # gives a plain Hash), but nested messages always convert field by field
    def __to_h # :nodoc:
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
    #: (untyped other) -> bool
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

    #: () -> Integer
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
    #: (?freeze: bool?) -> self
    def clone(freeze: nil)
      copy = dup
      copy.freeze if freeze || (freeze.nil? && frozen?)
      copy
    end

    # Freezes the message and everything it holds, after which it is Ractor.shareable?
    #: () -> self
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
    #: (self other) -> self
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
    #: () -> self
    def clear!
      __check_frozen
      __reset
      self
    end

    # Returns whether every required field is set, here and in every nested message.
    #: () -> bool
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

    #: () -> String
    def inspect
      parts = __shown.map { |name, v| "#{name}: #{v.inspect}" }
      name = self.class.descriptor.full_name
      parts.empty? ? "#<#{name}>" : "#<#{name} #{parts.join(", ")}>"
    end
    alias_method :to_s, :inspect

    # For `pp`: the fields `inspect` shows, one per line with nested
    # messages indented when they do not fit on one
    #: (untyped q) -> void
    def pretty_print(q)
      Message.__pretty_print(q, self.class.descriptor.full_name, __shown)
    end

    def self.__pretty_print(q, name, fields) # :nodoc:
      return q.text("#<#{name}>") if fields.empty?
      q.group(2, "#<#{name}", ">") do
        fields.each_with_index do |(field, v), i|
          q.text(",") if i > 0
          q.breakable
          q.text("#{field}: ")
          q.pp(v)
        end
      end
    end

    # The fields `inspect` shows: set, and not at their zero value
    #: () -> Array[[String, untyped]]
    def __shown # :nodoc:
      shown = []
      self.class.__fields.each do |info|
        v = @values[info.index]
        next if v.nil?
        next if (info.repeated || info.map) && v.empty?
        next if !info.presence && !info.repeated && !info.map && info.zero?(v)
        shown << [info.name, v]
      end
      shown
    end

    def __values # :nodoc:
      @values
    end

    def __reset # :nodoc:
      @values = self.class.__template.dup
      @unknown = nil
    end

    # Appends an unknown field; the decoder's way in
    def __add_unknown(field) # :nodoc:
      u = @unknown
      if u.nil?
        @unknown = [field]
      elsif u.frozen?
        @unknown = [*u, field]
      else
        u << field
      end
    end

    def __seal_unknown # :nodoc:
      @unknown&.freeze
    end

    def __set(index, value) # :nodoc:
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

    def __clear(index) # :nodoc:
      __check_frozen
      @values[index] = nil
    end

    # The stored Array or Hash of a repeated or map field, made on first use
    def __container(index) # :nodoc:
      info = self.class.__fields[index]
      if frozen?
        info.map ? EMPTY_HASH : EMPTY_ARRAY
      else
        @values[index] = info.map ? {} : []
      end
    end

    def __get(info) # :nodoc:
      v = @values[info.index]
      if info.repeated || info.map
        v || __container(info.index)
      elsif v.nil?
        info.default
      else
        v
      end
    end

    def self.__equal_values?(info, a, b) # :nodoc:
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

    def self.__hash_value(info, v) # :nodoc:
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

    def self.__copy_value(v) # :nodoc:
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
