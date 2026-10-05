# frozen_string_literal: true

module Protostar
  # Writes a message's wire bytes as a block runs, without building the
  # message. Protobuf merges by concatenation, so a builder needs no object
  # graph: each call writes its field at once.
  #
  #   bytes = Protostar::Builder.build(Acme::Person) do |pb|
  #     pb.name "Jane"                                    # written now
  #     pb.friends(people) { |p| pb.name p.name }         # one element per item
  #     pb.address { pb.street "x" }                      # nested, length-prefixed when the block ends
  #     pb.attrs("a" => "b")                              # a map
  #     pb.created_at Time.now                            # a Timestamp
  #     pb.extract! user, :email, :phone                  # fields read from an object
  #     pb.cache!("person/#{id}") { pb.bio bio }          # bytes cached; a hit appends them
  #   end
  #   person = Protostar::Builder.message(Acme::Person) { |pb| ... }
  #   Protostar::Builder.write(io, Acme::Person) { |pb| ... }
  #
  # A builder has one method per field name of the message and of every
  # message reachable from it; inside a nested block the same builder writes
  # the nested message's fields. Names that are also methods of Object (or of
  # the builder itself), such as `hash`, `format` or `test`, are reached with
  # {#set!}.
  #
  # Only what the wire format needs is held back: a nested message is built
  # into a buffer of its own because its length comes first, and packed
  # repeated scalars are collected per field and written as one run when
  # their message ends. Everything else goes straight to the target.
  #
  # Values are checked against the descriptor as they are written. Besides
  # what a message accepts, a builder takes `Time` and `DateTime` for a
  # `google.protobuf.Timestamp`, a Numeric for a `google.protobuf.Duration`,
  # a scalar for a wrapper type, a Hash or anything with `to_h` for a
  # message, and a message instance (written as its encoded bytes). `nil`
  # writes nothing. Errors raise {Error} with the path of the field.
  #
  # By default a singular field may be written once per message: writing it
  # again (or a second member of a oneof) raises. With `overwrites: true` the
  # later value is written as well and wins when the bytes are read, as
  # protobuf's merge rules say. Such output then relies on its reader
  # applying those rules (every conforming decoder does, protostar's
  # included); a reader promised that no field repeats will see the first
  # value instead.
  class Builder
    # Raised for a value a field cannot take, a field the message does not
    # have, or a field written twice without `overwrites: true`
    class Error < Protostar::Error
      # @return [String] where the problem is, as in `friends[2].address.street`
      attr_reader :path

      def initialize(message, path: nil)
        @path = path
        super((path.nil? || path.empty?) ? message : "#{path}: #{message}")
      end
    end

    # Stands for "no value given" in field methods, as nil is a value (it writes nothing)
    NONE = Object.new.freeze
    EMPTY = [].freeze
    F = Message::FieldInfo
    RANGES = Message::Coercion::RANGES
    ENUM_RANGE = Message::Coercion::ENUM_RANGE
    UTF_8 = Encoding::UTF_8
    BINARY = Encoding::BINARY
    # pack directive of a run of fixed-width values
    PACK = F::FIXED.transform_values { |(_, d)| "#{d}*".freeze }.freeze
    WRAPPERS = %w[
      DoubleValue FloatValue Int64Value UInt64Value Int32Value UInt32Value BoolValue StringValue BytesValue
    ].to_h { |n| ["google.protobuf.#{n}", :wrapper] }
    WELL_KNOWN = WRAPPERS.merge("google.protobuf.Timestamp" => :timestamp, "google.protobuf.Duration" => :duration).freeze

    class << self
      # @param klass [Class, Schema::Message] the message class, or its descriptor
      # @param options [Hash] see {#initialize}
      # @yieldparam pb [Builder]
      # @return [String] binary, the message's encoding
      def build(klass, **options)
        b = new(klass, nil, **options)
        yield b
        b.target!
      end

      # Builds the bytes and decodes them
      # @return [Message] an instance of `klass`
      def message(klass, **options, &block)
        klass = resolve(klass)
        klass.decode(build(klass, **options, &block))
      end

      # Streams the message to `io` as it is built, through a 64 KiB buffer.
      # Only the top level streams; each nested message is written once it is complete.
      # @param io [#write]
      # @return [#write] io
      def write(io, klass, **options)
        b = new(klass, io, **options)
        yield b
        b.target!
      end

      # @param klass [Class, Schema::Message]
      # @param target [String, IO, nil] where the bytes go: nil for a new String
      # @return [Builder] an instance of the builder class for `klass`
      def new(klass, target = nil, **options)
        return super if superclass.equal?(Builder)
        self.for(klass).new(klass, target, **options)
      end

      # The builder class for a message class: a subclass of Builder with one
      # method per field name of the message and of every message it reaches.
      # Made on first use and kept on the message class (in the main Ractor;
      # other Ractors make their own).
      # @return [Class]
      def for(klass)
        klass = resolve(klass)
        made = klass.instance_variable_get(:@__builder)
        return made if made
        made = Generator.generate(klass)
        klass.instance_variable_set(:@__builder, made) if Ractor.current.equal?(Ractor.main)
        made
      end

      # @return [Class] the message class for a class or a descriptor
      def resolve(klass)
        return klass if klass.is_a?(Class) && klass < Message && klass.__fields
        if klass.is_a?(Schema::Message)
          return Types.find(klass.full_name) || raise(ArgumentError, "#{klass.full_name} has no class in Protostar::Types.registry")
        end
        return resolve(klass.msgclass) if klass.respond_to?(:msgclass)
        raise ArgumentError, "#{klass.inspect} is not a protostar message class or descriptor"
      end
    end

    # @param klass [Class, Schema::Message] the message class, or its descriptor
    # @param target [String, IO, nil] a String to append to, an IO, or nil for a new String
    # @param cache_store [#fetch, nil] where {#cache!} keeps fragments, such as
    #   `Rails.cache`; without one, {#cache!} just runs its block
    # @param overwrites [Boolean] let a singular field be written again in the
    #   same message, the later value winning (see the class notes)
    # @param repeated [Symbol] `:append` (default): each write to a repeated field
    #   adds elements. `:replace`: assigning a list (or one value without a block)
    #   replaces what earlier assignments in the same message gave; those lists
    #   are held until the message ends. Elements built with a block always stream.
    def initialize(klass, target = nil, cache_store: nil, overwrites: false, repeated: :append)
      raise ArgumentError, "repeated: must be :append or :replace" unless repeated == :append || repeated == :replace
      @root = self.class::CLASSES[0]
      @w = Wire::Writer.new(target)
      @buf = @w.string
      @k = 0
      @written = 0
      @pending = nil
      @path = []
      @spare = []
      @store = cache_store
      @overwrites = overwrites
      @replace = repeated == :replace
    end

    # Finishes the top-level message: writes the packed runs collected so far,
    # in field number order.
    # The builder can keep writing afterwards; call this again to finish again.
    # @return [String, IO] the bytes, or the IO after flushing it
    def target!
      __flush_pending if @pending
      if @w.io
        @w.flush
        @w.io
      else
        @buf
      end
    end

    # @return [Class] the class of the message being written: the top-level
    #   one, or the nested message whose block is running
    def message_class
      self.class::CLASSES[@k]
    end

    # Writes a field by name, for names that have no method of their own.
    #
    #   pb.set! :name, "Jane"
    #   pb.set!(:address) { pb.street "x" }
    #   pb.set! :friends, people, :name, :id    # each friend gets name and id from an element
    #   pb.set! :address, user, :street, :city  # extract! into the nested message
    #
    # @param name [String, Symbol]
    # @param value [Object] the value; a collection with a block or attribute names
    # @param attributes [Array<Symbol>] read from `value` (or from each element) with {#extract!}
    # @return [self]
    def set!(name, value = NONE, *attributes, &block)
      __set(__field(name), value, attributes, &block)
      self
    end

    # Writes the named fields with the values of the same names read from
    # `object`: method calls, or keys for a Hash (Symbol or String keys).
    # @return [self]
    def extract!(object, *names)
      if object.is_a?(Hash)
        names.each do |n|
          v = object.fetch(n) { object.fetch(n.is_a?(Symbol) ? n.name : n.to_sym, nil) }
          __put(__field(n), v)
        end
      else
        names.each { |n| __put(__field(n), object.public_send(n)) }
      end
      self
    end

    # Writes every field of a Hash (Symbol or String keys), as {#set!} would
    # @return [self]
    def merge!(hash)
      raise __error(nil, "merge! takes a Hash, got #{hash.class}") unless hash.is_a?(Hash)
      __hash(hash)
      self
    end

    # Writes messages that are already encoded as the value of a message
    # field: one String for a singular field, a list of them for a repeated
    # one (each String is one element). The bytes are written as they are,
    # unchecked; a group's bytes are its fields, without the group's tags.
    #
    #   pb.encoded!(:friends, rendered_partials)
    #
    # @return [self]
    def encoded!(name, bytes)
      info = __field(name)
      raise __error(info, "is not a message field, it cannot take encoded messages") unless info.message? && !info.map
      if info.repeated
        __list(bytes).each_with_index { |b, i| __encoded(info, b, i) }
      else
        __mark(info)
        __encoded(info, bytes, nil)
      end
      self
    end

    # Writes the bytes the block writes, keeping them in the cache store under
    # `key`; when the store has them, appends them without running the block.
    # Without a cache store, runs the block.
    # @param key [Object] passed to the store as it is
    # @param options [Hash] passed to the store's `fetch`, such as `expires_in:`
    # @yieldparam pb [Builder] this builder
    # @return [self]
    def cache!(key, **options, &block)
      store = @store
      return tap(&block) unless store
      missed = false
      miss = proc do
        missed = true
        __capture(block)
      end
      bytes = options.empty? ? store.fetch(key, &miss) : store.fetch(key, options, &miss)
      raise __error(nil, "the cache store returned a #{bytes.class} for #{key.inspect}, not bytes") unless bytes.is_a?(String)
      __mark_fragment(bytes) unless missed
      @w.write_raw(bytes)
      self
    end

    # {#cache!} when `condition` holds, else runs the block
    # @return [self]
    def cache_if!(condition, key, **options, &block)
      condition ? cache!(key, **options, &block) : tap(&block)
    end

    def inspect
      path = __path(nil)
      "#<#{Builder.name} #{@root.descriptor.full_name}#{" at #{path}" unless path.empty?}>"
    end

    private

    def __field(name)
      self.class::BY_NAME[@k][name] || __no_field(name)
    end

    def __no_field(name)
      raise __error(nil, "#{self.class::CLASSES[@k].descriptor.full_name} has no field #{name.to_s.inspect}")
    end

    # Everything a field method or set! can be given. The block is only
    # yielded to, never made into a Proc, which would cost an object per call.
    def __set(info, value, attributes)
      if block_given?
        unless info.message? && !info.map
          raise __error(info, "is not a message field, it cannot take a block")
        end
        if info.repeated
          raise __error(info, "needs a collection to go with the block") if NONE.equal?(value)
          __each(info, value) { |e| yield e }
        else
          __mark(info)
          NONE.equal?(value) ? __nested(info) { yield } : __nested(info) { yield value }
        end
      elsif NONE.equal?(value)
        raise __error(info, "needs a value or a block")
      elsif !attributes.empty?
        raise __error(info, "is not a message field, it cannot extract attributes") unless info.message? && !info.map
        if info.repeated
          __each(info, value) { |e| extract!(e, *attributes) }
        else
          __mark(info)
          __nested(info) { extract!(value, *attributes) }
        end
      else
        __put(info, value)
      end
    end

    # One value for a field, without a block
    def __put(info, value)
      return if value.nil?
      if info.map
        __map(info, value)
      elsif info.repeated
        __repeated(info, value)
      elsif info.message?
        __mark(info)
        __message(info, value, nil)
      else
        again = __mark(info)
        __scalar(info, value, !again && !info.presence)
      end
    end

    # Records that a singular field was written in the current message.
    # @return [Boolean] whether it had been written before (with overwrites allowed)
    def __mark(info)
      bit = 1 << info.index
      if @written.anybits?(bit)
        return true if @overwrites
        if info.siblings && info.descriptor.real_oneof
          raise __error(info, "oneof #{info.descriptor.real_oneof.name} already has a value; " \
            "pass overwrites: true to let the last one win")
        end
        raise __error(info, "is already set; pass overwrites: true to let the last value win")
      end
      @written |= bit
      info.siblings&.each { |i| @written |= 1 << i }
      false
    end

    def __list(value)
      return value if value.is_a?(Array)
      return value.to_ary if value.respond_to?(:to_ary)
      [value]
    end

    def __repeated(info, value)
      list = __list(value)
      if info.packed
        run = (@pending ||= {}.compare_by_identity)[info]
        if run.nil? || @replace
          run = @pending[info] = []
        end
        list.each { |e| run << __packed_value(info, e) }
      elsif @replace
        (@pending ||= {}.compare_by_identity)[info] = list.dup
      else
        __elements(info, list)
      end
    end

    def __elements(info, list)
      if info.message?
        list.each_with_index { |e, i| __message(info, e, i) }
      else
        list.each { |e| __scalar(info, e, false) }
      end
    end

    def __each(info, collection)
      raise __error(info, "needs a collection (something with #each), got #{collection.class}") unless collection.respond_to?(:each)
      i = 0
      collection.each do |e|
        __nested(info, i) { yield e }
        i += 1
      end
    end

    def __hash(hash)
      by_name = self.class::BY_NAME[@k]
      hash.each do |name, v|
        __put(by_name[name] || __no_field(name), v)
      end
    end

    # A message value: an instance, a Hash, a well-known type's Ruby form, or anything with to_h
    def __message(info, v, index)
      klass = info.message_class
      if v.instance_of?(klass)
        __encoded(info, v.encode, index)
      elsif v.is_a?(Hash)
        __nested(info, index) { __hash(v) }
      elsif v.is_a?(Message)
        raise __error(info, "expects a #{klass.descriptor.full_name}, got a #{v.class.descriptor.full_name}", index)
      elsif (wk = WELL_KNOWN[klass.descriptor.full_name]) && __well_known(info, wk, v, index)
        nil
      elsif v.respond_to?(:to_h) && !v.is_a?(Array) && !v.is_a?(String)
        __nested(info, index) { __hash(v.to_h) }
      else
        raise __error(info, "expects a #{klass.descriptor.full_name}, a Hash or something with #to_h, got #{__show(v)}", index)
      end
    end

    def __encoded(info, bytes, index)
      raise __error(info, "expects encoded bytes in a String, got #{__show(bytes)}", index) unless bytes.is_a?(String)
      @buf << info.tag
      group = info.kind == F::GROUP
      __varint(bytes.bytesize) unless group
      @w.write_raw(bytes)
      @buf << info.end_tag if group
    end

    # @return [Boolean] whether `v` was a Ruby form of the well-known type and got written
    def __well_known(info, wk, v, index)
      fields = info.message_class.__fields
      case wk
      when :timestamp
        seconds, nanos = WellKnown::Timestamp.parts(v)
        return false unless seconds
        __nested(info, index) do
          __put(fields[0], seconds)
          __put(fields[1], nanos)
        end
      when :duration
        seconds, nanos = __duration(info, v, index)
        return false unless seconds
        __nested(info, index) do
          __put(fields[0], seconds)
          __put(fields[1], nanos)
        end
      else
        return false if v.respond_to?(:to_h) && !v.is_a?(String)
        __nested(info, index) { __put(fields[0], v) }
      end
      true
    end

    def __duration(info, v, index)
      WellKnown::Duration.parts(v)
    rescue FloatDomainError
      raise __error(info, "expects a finite duration, got #{__show(v)}", index)
    rescue RangeError
      raise __error(info, "is out of Duration's range: #{__show(v)}", index)
    end

    # Runs the block with a buffer of its own as the current message, then
    # writes tag, length and the buffer. Groups need no length and are
    # written in place between their tags.
    def __nested(info, index = nil)
      k = self.class::INDEX[info.message_class]
      saved_k = @k
      saved_written = @written
      saved_pending = @pending
      @path << info
      @path << index if index
      if info.kind == F::GROUP
        @buf << info.tag
        begin
          @k = k
          @written = 0
          @pending = nil
          yield
          __flush_pending if @pending
        ensure
          @k = saved_k
          @written = saved_written
          @pending = saved_pending
          @path.pop
          @path.pop if index
        end
        @buf << info.end_tag
        return
      end
      saved_w = @w
      saved_buf = @buf
      child = @spare.pop || Wire::Writer.new
      begin
        @w = child
        @buf = child.string
        @k = k
        @written = 0
        @pending = nil
        yield
        __flush_pending if @pending
      ensure
        @w = saved_w
        @buf = saved_buf
        @k = saved_k
        @written = saved_written
        @pending = saved_pending
        @path.pop
        @path.pop if index
      end
      bytes = child.string
      @buf << info.tag
      __varint(bytes.bytesize)
      @w.write_raw(bytes)
      bytes.clear
      @spare << child
    end

    def __map(info, value)
      unless value.is_a?(Hash)
        raise __error(info, "is a map, it takes a Hash, got #{__show(value)}") unless value.respond_to?(:to_hash)
        value = value.to_hash
      end
      key = info.key
      val = info.value
      saved_w = @w
      saved_buf = @buf
      value.each do |k, v|
        child = @spare.pop || Wire::Writer.new
        @path << info << k
        begin
          @w = child
          @buf = child.string
          __scalar(key, k, false)
          raise __error(nil, "a map value cannot be nil") if v.nil?
          val.message? ? __message(val, v, nil) : __scalar(val, v, false)
        ensure
          @w = saved_w
          @buf = saved_buf
          @path.pop(2)
        end
        bytes = child.string
        @buf << info.tag
        __varint(bytes.bytesize)
        @w.write_raw(bytes)
        bytes.clear
        @spare << child
      end
    end

    def __varint(n)
      if n < 0x80 && n >= 0
        @buf << n
      else
        @w.write_varint(n)
      end
    end

    # Writes tag and value of a scalar; with `skip_zero`, writes nothing for the type's zero value
    def __scalar(info, v, skip_zero)
      buf = @buf
      case info.kind
      when F::STRING
        v = __utf8(info, v)
        return if skip_zero && v.empty?
        buf << info.tag
        __varint(v.bytesize)
        @w.write_raw(v)
      when F::BYTES
        raise __error(info, "expects a String, got #{__show(v)}") unless v.is_a?(String)
        return if skip_zero && v.empty?
        buf << info.tag
        __varint(v.bytesize)
        @w.write_raw(v)
      when F::INT32, F::INT64, F::UINT32, F::UINT64
        __int(info, v)
        return if skip_zero && v == 0
        buf << info.tag
        __varint(v)
      when F::SINT32, F::SINT64
        __int(info, v)
        return if skip_zero && v == 0
        buf << info.tag
        __varint((v << 1) ^ (v >> 63))
      when F::BOOL
        raise __error(info, "expects true or false, got #{__show(v)}") unless v == true || v == false
        return if skip_zero && !v
        buf << info.tag << (v ? 1 : 0)
      when F::ENUM
        n = __enum(info, v)
        return if skip_zero && n == 0
        buf << info.tag
        __varint(n)
      when F::DOUBLE, F::FLOAT
        f = __float(info, v)
        return if skip_zero && f == 0 && (1.0 / f) > 0
        buf << info.tag
        if info.kind == F::DOUBLE
          [f].pack("E", buffer: buf)
        elsif f.nan?
          buf << Wire.float_nan(f)
        else
          [f].pack("e", buffer: buf)
        end
      else
        __int(info, v)
        return if skip_zero && v == 0
        buf << info.tag
        [v].pack(F::FIXED.fetch(info.kind)[1], buffer: buf)
      end
    end

    # A packed element as the run will hold it: an Integer (enum numbers
    # resolved, sint zigzagged), a Float, or 1 or 0 for bools
    def __packed_value(info, v)
      case info.kind
      when F::ENUM then __enum(info, v)
      when F::BOOL
        raise __error(info, "expects true or false, got #{__show(v)}") unless v == true || v == false
        v ? 1 : 0
      when F::DOUBLE, F::FLOAT then __float(info, v)
      when F::SINT32, F::SINT64
        __int(info, v)
        (v << 1) ^ (v >> 63)
      else
        __int(info, v)
        v
      end
    end

    def __flush_pending
      pending = @pending
      @pending = nil
      fields = pending.keys
      fields.sort_by!(&:number) if fields.size > 1
      fields.each do |info|
        list = pending[info]
        if info.packed
          __packed(info, list) unless list.empty?
        else
          __elements(info, list)
        end
      end
    end

    def __packed(info, list)
      @buf << info.packed_tag
      if (format = PACK[info.kind])
        __varint(F::FIXED.fetch(info.kind)[0] * list.size)
        if info.kind == F::FLOAT
          @buf << Wire.pack_floats(list)
        else
          list.pack(format, buffer: @buf)
        end
      elsif info.kind == F::BOOL
        __varint(list.size)
        list.each { |b| @buf << b }
      else
        __varint(list.sum { |n| Wire.varint_size(n) })
        list.each { |n| __varint(n) }
      end
      @w.flush_if_full
    end

    def __int(info, v)
      return if v.is_a?(Integer) && RANGES.fetch(info.kind).cover?(v)
      raise __error(info, "expects an Integer in #{info.descriptor.type} range, got #{__show(v)}")
    end

    def __float(info, v)
      raise __error(info, "expects a Numeric, got #{__show(v)}") unless v.is_a?(Numeric)
      f = begin
        v.to_f
      rescue RangeError
        raise __error(info, "expects a real number, got #{__show(v)}")
      end
      (info.kind == F::FLOAT) ? Message::Coercion.float32(f) : f
    end

    def __utf8(info, v)
      raise __error(info, "expects a String, got #{__show(v)}") unless v.is_a?(String)
      enc = v.encoding
      if enc == UTF_8
        return v if v.valid_encoding?
      elsif enc == BINARY || enc == Encoding::US_ASCII
        return v if v.ascii_only? || v.dup.force_encoding(UTF_8).valid_encoding?
      else
        begin
          return v.encode(UTF_8)
        rescue EncodingError
          raise __error(info, "expects a String convertible to UTF-8, got #{__show(v)}")
        end
      end
      raise __error(info, "expects valid UTF-8, got #{__show(v)}")
    end

    def __enum(info, v)
      n = case v
      when Symbol then info.enum_numbers[v]
      when String then info.enum_numbers[v.to_sym]
      when Integer
        v if info.enum_names.key?(v) || (!info.closed_enum && ENUM_RANGE.cover?(v))
      end
      n || raise(__error(info, "expects a value of #{info.enum_module.descriptor.full_name}, got #{__show(v)}"))
    end

    # Runs a cache! block into a buffer of its own, in the current message
    # @return [String] the bytes, frozen
    def __capture(block)
      saved_w = @w
      saved_buf = @buf
      saved_pending = @pending
      child = @spare.pop || Wire::Writer.new
      begin
        @w = child
        @buf = child.string
        @pending = nil
        block.call(self)
        __flush_pending if @pending
      ensure
        @w = saved_w
        @buf = saved_buf
        @pending = saved_pending
      end
      bytes = child.string.dup.freeze
      child.string.clear
      @spare << child
      bytes
    end

    # A cached fragment's singular fields count as written, so that writing
    # one of them again is caught (or, with overwrites, written even when zero)
    def __mark_fragment(bytes)
      by_number = self.class::CLASSES[@k].__by_number
      r = Wire::Reader.new(bytes)
      until r.eof?
        number, wire_type = r.read_tag
        r.skip_field(number, wire_type)
        info = by_number[number]
        __mark(info) if info && !info.repeated && !info.map
      end
    rescue DecodeError => e
      raise __error(nil, "a cached fragment is not valid wire data (#{e.message})")
    end

    def __show(v)
      s = v.inspect
      (s.length > 64) ? "#{s[0, 60]}..." : s
    end

    def __error(info, message, index = nil)
      Error.new(message, path: __path(info, index))
    end

    def __path(info, index = nil)
      out = +""
      segments = @path
      segments += [info] if info
      segments += [index] if index
      segments.each do |s|
        if s.is_a?(F)
          next unless s.index # a map's key and value
          out << "." unless out.empty?
          out << s.name
        elsif s.is_a?(Integer)
          out << "[#{s}]"
        else
          out << "[#{s.inspect}]"
        end
      end
      out
    end
  end
end

require_relative "builder/generator"

module Protostar
  class Message
    class << self
      # A message made with a {Builder} block, or with `new` when there is no
      # block. `fields` are written first; the block may set them again (the
      # bytes never leave the process, so overwrites are allowed).
      #
      #   person = Acme::Person.build(name: "Jane") do |pb|
      #     pb.address { pb.street "x" }
      #   end
      #
      # @param fields [Hash, nil] field names to values, as {#initialize} takes them
      # @yieldparam pb [Builder]
      # @return [Message]
      def build(fields = nil, **more, &block)
        return new(fields, **more) unless block
        Builder.message(self, overwrites: true) do |pb|
          pb.merge!(fields) if fields
          pb.merge!(more) unless more.empty?
          block.call(pb)
        end
      end
    end
  end
end
