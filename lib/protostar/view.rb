# frozen_string_literal: true

module Protostar
  # A read-only message over the bytes it was encoded in. Making a view
  # scans the top level once and keeps where each field is; nothing is
  # decoded until a reader asks, and what a reader decodes is kept. Nested
  # messages are views over slices of the same buffer, so reading one
  # field of a large message copies nothing but that field's value.
  #
  #   view = Person.view(bytes)          # a String or an IO::Buffer
  #   view.name                          # => "Ada"
  #   view.friends[2].name               # a nested view, same buffer
  #   view.encode.equal?(bytes)          # => true
  #   view.to_message                    # the mutable message, decoded eagerly
  #
  # Every message class has a view class, `Person::View` (or
  # `Person.view_class` when the message has a nested type called View),
  # with the same readers as the message: scalars, enums, `has_`, `which_`,
  # repeated fields as {Repeated}, maps as {Map}. Views are frozen; writers
  # raise FrozenError. A view reads the buffer it was given for as long as
  # it lives, so that buffer must not change underneath it.
  #
  # Malformed input raises {DecodeError} when the view is made, for the top
  # level; a nested message is checked when it is first read, and a string
  # with invalid UTF-8 when the string is read.
  class View
    class << self
      # @return [Class] the message class this view class reads
      attr_reader :message_class

      # @api private
      attr_reader :__fields, :__by_name, :__readers, :__unknown_slot

      # @return [Schema::Message]
      def descriptor
        @message_class.descriptor
      end

      def inspect
        name || "#<Class #{@message_class ? "#{@message_class.descriptor.full_name}::View" : "Protostar::View"}>"
      end

      # @api private
      def __define(message_class, fields)
        @message_class = message_class
        @__fields = message_class.__fields
        @__by_name = message_class.__by_name
        @__readers = Ractor.make_shareable(fields.map { |f| :"__f#{f.index}" })
        @__unknown_slot = 3 * fields.size
        self
      end

      # @api private
      def __new(buf, offset, length, segments, depth)
        new(buf, offset, length, segments, depth)
      end

      # @api private
      def __open(bytes, offset, length, depth)
        raise NotImplementedError, "#{self} is abstract; views come from message classes" unless @message_class
        buf = if bytes.is_a?(String)
          bytes
        elsif defined?(IO::Buffer) && bytes.is_a?(IO::Buffer)
          IOSource.new(bytes)
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

    # @return [Schema::Message]
    def descriptor
      self.class.descriptor
    end

    # @param name [String, Symbol]
    # @return [Object] what the field's reader returns
    # @raise [ArgumentError] when there is no such field
    def [](name)
      info = self.class.__by_name[name] || raise(ArgumentError, "#{descriptor.full_name} has no field #{name.inspect}")
      __send__(self.class.__readers[info.index])
    end

    # @raise [FrozenError] always
    def []=(_name, _value)
      __frozen!
    end

    # @raise [FrozenError] always
    def merge!(_other)
      __frozen!
    end

    # @raise [FrozenError] always
    def clear!
      __frozen!
    end

    # @return [Array<UnknownField>] frozen, in the order they occur
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

    # @return [String] the bytes this view reads: the very String it was
    #   made from when it covers all of it, otherwise a copy of its part
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

    # Decodes the view's bytes into a message, as {Message.decode} would
    # @param frozen [Boolean] return a deep-frozen, Ractor-shareable message
    # @return [Message]
    def to_message(frozen: false)
      msg = self.class.message_class.__empty
      buf = @buf
      depth = @depth
      __each_segment do |offset, length|
        c = Cursor.new(buf, offset + length)
        c.pos = offset
        msg.__decode_fields(c, depth, 0, frozen)
      end
      msg.freeze if frozen
      msg
    end

    # @return [Hash] what {Message#to_h} gives for the same bytes
    def to_h
      __to_h
    end

    # @api private
    def __to_h
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
    # same field values (unknown fields aside), as {Message#==} compares
    def ==(other)
      return true if equal?(other)
      case other
      when View then other.instance_of?(self.class) && to_message == other.to_message
      when Message then other.instance_of?(self.class.message_class) && to_message == other
      else false
      end
    end
    alias_method :eql?, :==

    def hash
      to_message.hash
    end

    # Reads every field, nested views and containers included, and freezes
    # what was read. A view over a frozen String is then Ractor-shareable.
    # @return [self]
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

    def inspect
      parts = []
      ix = @ix
      readers = self.class.__readers
      self.class.__fields.each do |info|
        next if ix[info.index].nil?
        v = __send__(readers[info.index])
        next if (info.repeated || info.map) && v.empty?
        next if !info.presence && !info.repeated && !info.map && info.zero?(v)
        parts << "#{info.name}: #{v.inspect}"
      end
      name = "view #{descriptor.full_name}"
      parts.empty? ? "#<#{name}>" : "#<#{name} #{parts.join(", ")}>"
    end
    alias_method :to_s, :inspect

    def pretty_print(q)
      q.text(inspect)
    end

    # @return [Array<Array(Integer, Integer)>] offset and length of each
    #   piece of the buffer this view reads, in order
    # @api private
    def __segments
      list = []
      __each_segment { |offset, length| list << [offset, length] }
      list
    end

    private

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

  class Message
    class << self
      # @api private
      attr_reader :__view_class

      # @return [Class] the {View} subclass whose instances read this class's messages
      def view_class
        @__view_class || raise(NotImplementedError, "#{self} is abstract; define message classes with Protostar::Types")
      end

      # A read-only view of an encoded message that decodes fields only when read
      # @param bytes [String, IO::Buffer] not copied; must not change while the view is used
      # @param offset [Integer] where the message starts in `bytes`
      # @param length [Integer, nil] its length, by default up to the end of `bytes`
      # @param recursion_limit [Integer] how deep messages may nest
      # @return [View]
      # @raise [DecodeError] when the top level of the message is malformed
      def view(bytes, offset: 0, length: nil, recursion_limit: Codec::Decoder::RECURSION_LIMIT)
        view_class.__open(bytes, offset, length, recursion_limit)
      end
    end
  end
end

require_relative "view/source"
require_relative "view/scan"
require_relative "view/repeated"
require_relative "view/map"
require_relative "view/generator"
