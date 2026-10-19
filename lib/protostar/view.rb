# frozen_string_literal: true

module Protostar
  # A read-only message over the bytes it was encoded in. Making a view
  # scans the top level once and keeps where each field is; nothing is
  # decoded until a reader asks, and what a reader decodes is kept. Nested
  # messages are views over slices of the same buffer, so reading one
  # field of a large message copies nothing but that field's value.
  #
  # ```ruby
  # view = Person.view(bytes)          # a String or an IO::Buffer
  # view.name                          # => "Ada"
  # view.friends[2].name               # a nested view, same buffer
  # view.encode.equal?(bytes)          # => true
  # view.to_message                    # the mutable message, decoded eagerly
  # ```
  #
  # Every message class has a view class, `Person.view_class`, with the
  # same readers as the message: scalars, enums, `has_`, `which_`,
  # repeated fields as Repeated, maps as Map. Views are frozen; writers
  # raise FrozenError. A view reads the buffer it was given for as long as
  # it lives, so that buffer must not change underneath it.
  #
  # Malformed input raises DecodeError when the view is made, for the top
  # level; a nested message is checked when it is first read, and a string
  # with invalid UTF-8 when the string is read.
  class View
    class << self
      # The message class this view class reads.
      attr_reader :message_class #: singleton(Message)

      attr_reader :__fields, :__by_name, :__readers, :__unknown_slot # :nodoc:

      #: () -> Schema::Message
      def descriptor
        @message_class.descriptor
      end

      def inspect
        name || "#<Class #{@message_class ? "#{@message_class.descriptor.full_name}::View" : "Protostar::View"}>"
      end

      def __define(message_class, fields) # :nodoc:
        @message_class = message_class
        @__fields = message_class.__fields
        @__by_name = message_class.__by_name
        @__readers = Ractor.make_shareable(fields.map { |f| :"__f#{f.index}" })
        @__unknown_slot = 3 * fields.size
        self
      end

      def __new(buf, offset, length, segments, depth) # :nodoc:
        new(buf, offset, length, segments, depth)
      end

      def __open(bytes, offset, length, depth) # :nodoc:
        raise NotImplementedError, "#{self} is abstract; views come from message classes" unless @message_class
        buf = if bytes.is_a?(String)
          bytes
        elsif defined?(IO::Buffer) && bytes.is_a?(IO::Buffer)
          Wire::IOSource.new(bytes)
        else
          raise ::TypeError, "expected a String or IO::Buffer, got #{bytes.class}"
        end
        size = buf.bytesize
        length ||= size - offset
        if offset < 0 || length < 0 || offset + length > size
          raise ArgumentError, "offset #{offset} and length #{length} do not fit a buffer of #{size} bytes"
        end
        new(buf, offset, length, nil, depth)
      end

      private :new
    end

    #: () -> Schema::Message
    def descriptor
      self.class.descriptor
    end

    # Returns what the field's reader returns.
    # Raises ArgumentError when there is no such field.
    #: (String | Symbol name) -> untyped
    def [](name)
      info = self.class.__by_name[name] || raise(ArgumentError, "#{descriptor.full_name} has no field #{name.inspect}")
      __send__(self.class.__readers[info.index])
    end

    # Raises FrozenError always.
    def []=(_name, _value)
      __frozen!
    end

    # Raises FrozenError always.
    def merge!(_other)
      __frozen!
    end

    # Raises FrozenError always.
    def clear!
      __frozen!
    end

    # Returns them frozen, in the order they occur.
    #: () -> Array[UnknownField]
    def unknown_fields
      ix = @ix
      u = self.class.__unknown_slot
      cached = ix[u + 1]
      return cached if cached
      ranges = ix[u]
      return Message::EMPTY_ARRAY if ranges.nil?
      list = []
      k = 0
      while k < ranges.size
        start = ranges[k + 2]
        bytes = @buf.byteslice(start, ranges[k + 3] - start).force_encoding(Encoding::BINARY).freeze
        list << UnknownField.new(ranges[k], ranges[k + 1], bytes)
        k += 4
      end
      ix[u + 1] = list.freeze
    end

    # Returns the bytes this view reads: the very String it was
    # made from when it covers all of it, otherwise a copy of its part.
    #: () -> String
    def encode
      buf = @buf
      if @segs.nil?
        return buf if @off == 0 && buf.is_a?(String) && @len == buf.bytesize
        return buf.byteslice(@off, @len).force_encoding(Encoding::BINARY)
      end
      out = (+"").force_encoding(Encoding::BINARY)
      __each_segment { |offset, length| out << buf.byteslice(offset, length) }
      out
    end
    alias_method :to_proto, :encode

    # Decodes the view's bytes into a message, as Message.decode would
    #
    # - `frozen`: return a deep-frozen, Ractor-shareable message
    #: (?frozen: bool) -> Message
    def to_message(frozen: false)
      msg = self.class.message_class.__empty
      buf = @buf
      depth = @depth
      __each_segment do |offset, length|
        c = Wire::Reader.new(buf, offset, offset + length)
        msg.__decode_fields(c, depth, 0, frozen)
      end
      msg.freeze if frozen
      msg
    end

    # Returns what Message#to_h gives for the same bytes.
    #: () -> Hash[Symbol, untyped]
    def to_h
      __to_h
    end

    def __to_h # :nodoc:
      h = {}
      ix = @ix
      readers = self.class.__readers
      self.class.__fields.each do |info|
        next if ix[info.index].nil?
        v = __send__(readers[info.index])
        if info.map
          next if v.empty?
          h[info.symbol] = info.value.message? ? v.to_h.transform_values(&:__to_h) : v.to_h.dup
        elsif info.repeated
          next if v.empty?
          h[info.symbol] = info.message? ? v.map(&:__to_h) : v.to_a.dup
        elsif info.message?
          h[info.symbol] = v.__to_h
        elsif info.presence || !info.zero?(v)
          h[info.symbol] = v
        end
      end
      h
    end

    # Equal to a message of the view's class, or a view of it, with the
    # same field values (unknown fields aside), as Message#== compares
    #: (untyped other) -> bool
    def ==(other)
      return true if equal?(other)
      case other
      when View then other.instance_of?(self.class) && to_message == other.to_message
      when Message then other.instance_of?(self.class.message_class) && to_message == other
      else false
      end
    end
    alias_method :eql?, :==

    #: () -> Integer
    def hash
      to_message.hash
    end

    # Reads every field, nested views and containers included, and freezes
    # what was read. A view over a frozen String is then Ractor-shareable.
    #: () -> self
    def freeze_index
      ix = @ix
      return self if ix.frozen?
      readers = self.class.__readers
      self.class.__fields.each do |info|
        next if ix[info.index].nil?
        v = __send__(readers[info.index])
        v.freeze_index if v.is_a?(View) || v.is_a?(Repeated) || v.is_a?(Map)
      end
      unknown_fields
      ix.each { |e| e.freeze if e.is_a?(Array) }
      @segs&.freeze
      ix.freeze
      self
    end

    #: () -> String
    def inspect
      parts = __shown.map { |name, v| "#{name}: #{v.inspect}" }
      name = "view #{descriptor.full_name}"
      parts.empty? ? "#<#{name}>" : "#<#{name} #{parts.join(", ")}>"
    end
    alias_method :to_s, :inspect

    # For `pp`, laid out as Message#pretty_print lays out messages
    #: (untyped q) -> void
    def pretty_print(q)
      Message.__pretty_print(q, "view #{descriptor.full_name}", __shown)
    end

    # Returns the fields `inspect` shows.
    #: () -> Array[[String, untyped]]
    def __shown # :nodoc:
      shown = []
      ix = @ix
      readers = self.class.__readers
      self.class.__fields.each do |info|
        next if ix[info.index].nil?
        v = __send__(readers[info.index])
        next if (info.repeated || info.map) && v.empty?
        next if !info.presence && !info.repeated && !info.map && info.zero?(v)
        shown << [info.name, v]
      end
      shown
    end

    # Returns offset and length of each
    # piece of the buffer this view reads, in order.
    #: () -> Array[[Integer, Integer]]
    def __segments # :nodoc:
      list = []
      __each_segment { |offset, length| list << [offset, length] }
      list
    end

    private

    #: () { (Integer, Integer) -> void } -> void
    def __each_segment
      segs = @segs
      if segs.nil?
        yield @off, @len
      else
        k = 0
        while k < segs.size
          yield segs[k], segs[k + 1]
          k += 2
        end
      end
    end

    def __nested(i, o, n)
      info = self.class.__fields[i]
      o.is_a?(Integer) ? Scan.nested(info, @buf, [o, n], @depth) : Scan.nested(info, @buf, o, @depth)
    end

    def __frozen!
      raise FrozenError.new("can't modify a view of #{descriptor.full_name}", receiver: self)
    end
  end
end

require_relative "view/scan"
require_relative "view/repeated"
require_relative "view/map"
require_relative "view/generator"
