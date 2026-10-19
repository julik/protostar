# frozen_string_literal: true

module Google
  module Protobuf
    module Internal
      # Turns a class protostar's registry made into a google-protobuf
      # message class: the gem's class and instance methods are mixed in,
      # and the field accessors are defined in a module prepended to the class.
      module MessageClass # :nodoc: all
        module_function

        # - `klass`: a subclass of AbstractMessage
        #: (Class klass, Descriptor descriptor) -> untyped
        def setup(klass, descriptor)
          descriptor.__msgclass = klass
          plan = Array.new(klass.__fields.size)
          klass.__fields.each { |info| plan[info.index] = descriptor.lookup(info.name) }
          oneofs = []
          descriptor.each_oneof { |o| oneofs << o }
          klass.instance_variable_set(:@__gdescriptor, descriptor)
          klass.instance_variable_set(:@__gplan, plan.freeze)
          klass.instance_variable_set(:@__gnames, plan.to_h { |fd| [fd.name, fd] }.freeze)
          klass.instance_variable_set(:@__goneof_setters, oneofs.to_h { |o| [:"#{o.name}=", true] }.freeze)
          klass.instance_variable_set(:@__gnested, klass.__fields.select { |i| i.map ? i.value.message? : i.message? }.freeze)
          klass.include(MessageMethods)
          klass.extend(ClassMethods)
          accessors = Module.new
          taken = reserved.dup
          src = +""
          plan.each { |fd| define_field(accessors, fd, taken, src) }
          oneofs.each { |o| define_oneof(accessors, o, taken) }
          accessors.module_eval(src, "(google-protobuf #{descriptor.name})", 1)
          klass.prepend(accessors)
          if (well_known = WellKnown::MIXINS[descriptor.name])
            klass.include(well_known)
            klass.extend(well_known::ClassMethods)
          end
        end

        # Methods a message already has; a field named like one is reached through [] and []=
        def reserved
          @reserved ||= (Object.public_instance_methods + Protostar::Message.public_instance_methods +
            MessageExts.public_instance_methods + MessageMethods.public_instance_methods + %i[initialize])
            .to_h { |m| [m, true] }.freeze
        end

        # Readers that only read the field's variable are source, which YJIT
        # runs faster than a block
        def define_field(mod, fd, taken, src)
          info = fd.__info
          iv = info.ivar
          name = fd.name
          claim = ->(method) { !taken[method] && (taken[method] = true) }
          if claim.call(name.to_sym)
            if info.map
              mod.define_method(name) { __gmap(fd) }
            elsif info.repeated
              mod.define_method(name) { __grepeated(fd) }
            elsif info.presence && !info.message?
              default = Protostar::Message::Accessors.default_literal(info)
              src << "def #{name}; v = #{iv}; v.nil? ? #{default} : v; end\n"
            else
              src << "def #{name}; #{iv}; end\n"
            end
          end
          mod.define_method(:"#{name}=") { |v| __gset(fd, v) } if claim.call(:"#{name}=")
          mod.define_method(:"clear_#{name}") { __gclear(fd) } if claim.call(:"clear_#{name}")
          src << "def has_#{name}?; !#{iv}.nil?; end\n" if info.presence && claim.call(:"has_#{name}?")
          if fd.type == :enum && claim.call(:"#{name}_const")
            if info.repeated
              mod.define_method(:"#{name}_const") { __grepeated(fd).map { |v| fd.subtype.__numbers.fetch(v, v) } }
            else
              mod.define_method(:"#{name}_const") do
                v = instance_variable_get(iv)
                v = info.default if v.nil?
                fd.subtype.__numbers.fetch(v, v)
              end
            end
          end
          return unless !info.repeated && fd.wrapper?
          src << "def #{name}_as_value; #{iv}&.value; end\n" if claim.call(:"#{name}_as_value")
          if claim.call(:"#{name}_as_value=")
            mod.define_method(:"#{name}_as_value=") do |v|
              if v.nil?
                __gclear(fd)
              else
                sub = fd.subtype
                value_fd = sub.lookup("value")
                __gset(fd, sub.msgclass.new(value: Convert.to_store(v, value_fd.type, nil, name)))
              end
            end
          end
        end

        def define_oneof(mod, oneof, taken)
          name = oneof.name
          fields = oneof.map { |fd| [fd.__info.index, fd.name.to_sym] }.freeze
          if !taken[name.to_sym] && (taken[name.to_sym] = true)
            mod.define_method(name) do
              fields.each { |slot, member| return member unless __slot(slot).nil? }
              nil
            end
          end
          if !taken[:"clear_#{name}"] && (taken[:"clear_#{name}"] = true)
            mod.define_method(:"clear_#{name}") do
              __check_gfrozen
              fields.each { |slot, _| __set_slot(slot, nil) }
              nil
            end
          end
          if !taken[:"has_#{name}?"] && (taken[:"has_#{name}?"] = true)
            mod.define_method(:"has_#{name}?") { fields.any? { |slot, _| !__slot(slot).nil? } }
          end
        end
      end

      # Class methods of every message class
      module ClassMethods # :nodoc: all
        MAX_INPUT = 0x7FFF_FFFF

        #: () -> Descriptor
        def descriptor
          @__gdescriptor
        end

        attr_reader :__gplan, :__gnames, :__goneof_setters, :__gnested # :nodoc:

        # - `data`: protobuf wire format
        # - `options`: `recursion_limit:` how deep messages may nest (default 100)
        #
        # Raises ParseError.
        #: (String data, ?Hash[untyped, untyped] options) -> Protostar::Message
        def decode(data, options = {})
          raise ArgumentError, "Expected hash arguments." unless options.is_a?(Hash)
          raise ArgumentError, "Expected string for binary protobuf data." unless data.is_a?(String)
          # upb refuses input of 2 GiB or more, the most the wire format can describe
          raise ParseError, "Error occurred during parsing" if data.bytesize > MAX_INPUT
          limit = options[:recursion_limit]
          limit = limit.is_a?(Numeric) ? limit.to_i : Protostar::Codec::Decoder::RECURSION_LIMIT
          Protostar::Codec::Decoder.decode(self, data, recursion_limit: limit)
        rescue Protostar::DecodeError
          raise ParseError, "Error occurred during parsing"
        end

        # - `message`: an instance of this class
        # - `options`: `recursion_limit:` how deep messages may nest (default 100)
        #
        # Returns binary, frozen.
        #: (Protostar::Message message, ?Hash[untyped, untyped] options) -> String
        def encode(message, options = {})
          raise ArgumentError, "Message of wrong type." unless message.is_a?(self)
          raise ArgumentError, "Expected hash arguments." unless options.is_a?(Hash)
          limit = options[:recursion_limit]
          limit = limit.is_a?(Numeric) ? limit.to_i : Protostar::Codec::Decoder::RECURSION_LIMIT
          raise "Exceeded maximum depth (possibly cycle)" if message.__gdepth(limit + 1) > limit
          Protostar::Codec::Encoder.encode(message)
        rescue Protostar::EncodeError => e
          raise TypeError, e.message
        end

        # - `data`: JSON
        # - `options`: `ignore_unknown_fields:`
        #
        # Raises ParseError.
        #: (String data, ?Hash[untyped, untyped] options) -> Protostar::Message
        def decode_json(data, options = {})
          raise ArgumentError, "Expected hash arguments." unless options.is_a?(Hash)
          raise ArgumentError, "Expected string for JSON data." unless data.is_a?(String)
          raise "Cannot parse a wrapper directly" if descriptor.send(:wrapper?)
          # upb reads empty input as an empty message
          return new if data.empty?
          Internal::Json.decode(self, data, options)
        end

        # - `message`: an instance of this class
        # - `options`: `preserve_proto_fieldnames:`, `emit_defaults:`, `format_enums_as_integers:`
        #
        # Returns UTF-8, frozen.
        #: (Protostar::Message message, ?Hash[untyped, untyped] options) -> String
        def encode_json(message, options = {})
          Internal::Json.encode(message, Internal.options_hash(options))
        end

        def __gpool # :nodoc:
          @__gdescriptor.descriptor_pool
        end
      end

      # The options Hash the gem's methods take, from a Hash or anything with to_h
      def self.options_hash(options) # :nodoc:
        return options if options.is_a?(Hash)
        return options.to_h if options.respond_to?(:to_h)
        raise ArgumentError, "Expected hash arguments."
      end

      # Instance methods of every message class
      module MessageMethods # :nodoc: all
        NOTHING = Object.new.freeze
        private_constant :NOTHING

        # - `initial_value`: field names (Strings or Symbols) to values;
        #   Hashes become messages, Arrays repeated fields, Hashes map fields
        #
        # Raises ArgumentError for a name that is not a field.
        #: (?Hash[untyped, untyped]? initial_value) -> void
        def initialize(initial_value = NOTHING)
          super()
          return if NOTHING.equal?(initial_value)
          unless initial_value.is_a?(Hash)
            raise ArgumentError, "Expected hash arguments or message, not #{initial_value.class}"
          end
          names = self.class.__gnames
          initial_value.each do |key, value|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "Expected string or symbols as hash keys when initializing proto from hash."
            end
            fd = names[key.to_s]
            raise ArgumentError, "Unknown field name '#{key}' in initialization map entry." unless fd
            __ginit(fd, value) unless value.nil?
          end
        end

        # Returns the field's value; nil when there is no such field.
        #: (String name) -> untyped
        def [](name)
          raise ::TypeError, "wrong argument type #{name.class} (expected String)" unless name.is_a?(String)
          fd = self.class.__gnames[name]
          fd && __gget(fd)
        end

        # Raises ArgumentError when there is no such field.
        #: (String name, untyped value) -> untyped
        def []=(name, value)
          raise ::TypeError, "wrong argument type #{name.class} (expected String)" unless name.is_a?(String)
          fd = self.class.__gnames[name]
          raise ArgumentError, "Unknown field: #{name}" unless fd
          __gset(fd, value)
        end

        # Returns Symbol keys; fields with presence when set, others
        # when not at their default; nested messages as Hashes.
        #: () -> Hash[untyped, untyped]
        def to_h
          __to_h
        end

        def inspect
          parts = []
          values = __slots
          self.class.__gplan.each do |fd|
            info = fd.__info
            v = values[info.index]
            if info.map
              entries = (v || {}).map { |k, e| "#{k.inspect}=>#{e.inspect}" }
              parts << "#{fd.name}: {#{entries.join(", ")}}"
            elsif info.repeated
              parts << "#{fd.name}: [#{(v || []).map(&:inspect).join(", ")}]"
            elsif info.presence
              parts << "#{fd.name}: #{v.inspect}" unless v.nil?
            else
              parts << "#{fd.name}: #{v.inspect}"
            end
          end
          "<#{self.class.name || Module.instance_method(:to_s).bind_call(self.class)}: #{parts.join(", ")}>"
        end

        def to_s
          inspect
        end

        def pretty_print(q)
          q.text(inspect)
        end

        # Same class and the same field values, extensions included. The gem
        # compares encodings, so -0.0 differs from 0.0
        def ==(other)
          return true if equal?(other)
          return false unless other.instance_of?(self.class)
          super && __gextensions == other.__gextensions && __gsame_zeros?(other)
        end

        def eql?(other)
          self == other
        end

        def hash
          super
        end

        # A shallow copy, as the gem's: nested messages, repeated fields and
        # maps are shared with the original, and a copy of a frozen message
        # is frozen
        def dup
          copy = self.class.allocate
          copy.__gcopy_from(self)
          copy.freeze if frozen?
          copy
        end

        def clone
          dup
        end

        # Freezes the message and everything in it
        #: () -> self
        def freeze
          @__gwrappers ||= {} unless frozen?
          super
        end

        def __gcopy_from(source) # :nodoc:
          __load_slots(source.__slots)
          @unknown = source.unknown_fields.empty? ? nil : source.unknown_fields.dup.freeze
          @__gwrappers = nil
        end

        # Returns a copy with every nested message copied too.
        #: () -> Protostar::Message
        def __gdeep_copy # :nodoc:
          copy = self.class.allocate
          copy.__gdeep_from(self)
          copy
        end

        def __gdeep_from(source) # :nodoc:
          __load_slots(source.__slots.map! { |v| Internal.deep_copy_value(v) })
          @unknown = source.unknown_fields.empty? ? nil : source.unknown_fields.dup.freeze
          @__gwrappers = nil
        end

        #: (FieldDescriptor fd) -> untyped
        def __gget(fd) # :nodoc:
          return __gext_get(fd) if fd.__extension?
          info = fd.__info
          if info.map
            __gmap(fd)
          elsif info.repeated
            __grepeated(fd)
          else
            v = __slot(info.index)
            (v.nil? && !info.message?) ? info.default : v
          end
        end

        def __ghas?(fd) # :nodoc:
          return __gext_has?(fd) if fd.__extension?
          !__slot(fd.__info.index).nil?
        end

        def __gset(fd, value) # :nodoc:
          __check_gfrozen
          return __gext_set(fd, value) if fd.__extension?
          info = fd.__info
          i = info.index
          if info.map
            raise TypeError, "Expected Map instance" unless value.is_a?(Map)
            value.__check_field(fd)
            __set_slot(i, value.__hash)
            (@__gwrappers ||= {})[i] = value
          elsif info.repeated
            raise TypeError, "Expected repeated field array" unless value.is_a?(RepeatedField)
            value.__check_field(fd)
            __set_slot(i, value.__array)
            (@__gwrappers ||= {})[i] = value
          elsif value.nil? && (info.message? || info.siblings)
            __set_slot(i, nil)
          else
            v = Convert.to_store(value, fd.type, fd.subtype, fd.name)
            info.siblings&.each { |s| __set_slot(s, nil) }
            __set_slot(i, v)
          end
          value
        end

        def __gclear(fd) # :nodoc:
          __check_gfrozen
          return __gext_clear(fd) if fd.__extension?
          info = fd.__info
          __set_slot(info.index, (info.presence || info.repeated || info.map) ? nil : info.default)
          nil
        end

        # Returns the field's, the same object while the field holds the same Array.
        #: (untyped fd) -> RepeatedField
        def __grepeated(fd) # :nodoc:
          __gcontainer(fd, RepeatedField, [])
        end

        # Returns the field's, the same object while the field holds the same Hash.
        #: (untyped fd) -> Map
        def __gmap(fd) # :nodoc:
          __gcontainer(fd, Map, {})
        end

        # The wrapper of a repeated or map field's storage, kept per slot so
        # that reading the field twice gives the same object; a frozen
        # message's wrappers are frozen
        def __gcontainer(fd, kind, empty)
          i = fd.__info.index
          storage = __slot(i)
          cache = @__gwrappers
          wrapper = cache&.[](i)
          frozen = frozen?
          return wrapper if wrapper && (storage.nil? ? frozen : wrapper.__storage.equal?(storage))
          if storage.nil?
            storage = frozen ? empty.freeze : __set_slot(i, empty)
          end
          wrapper = kind.__for_field(fd, storage)
          wrapper.freeze if frozen
          if cache
            cache[i] = wrapper
          elsif !frozen
            @__gwrappers = {i => wrapper}
          end
          wrapper
        end

        # Returns how deeply messages nest under this one, counting it; stops at `limit`.
        #: (untyped limit) -> Integer
        def __gdepth(limit) # :nodoc:
          nested = self.class.__gnested
          return 1 if nested.empty?
          return limit if limit <= 1
          deepest = 0
          nested.each do |info|
            v = __slot(info.index)
            next if v.nil?
            if info.map || info.repeated
              (info.map ? v.each_value : v).each do |m|
                d = m.__gdepth(limit - 1)
                deepest = d if d > deepest
                return limit if deepest + 1 >= limit
              end
            else
              d = v.__gdepth(limit - 1)
              deepest = d if d > deepest
              return limit if deepest + 1 >= limit
            end
          end
          deepest + 1
        end

        # Returns the unknown fields holding extensions, for comparison.
        #: () -> Array[Protostar::UnknownField]
        def __gextensions # :nodoc:
          descriptor = self.class.descriptor.__schema
          return Protostar::Message::EMPTY_ARRAY if descriptor.extension_ranges.empty?
          unknown_fields.sort_by(&:number).map(&:to_wire)
        end

        private

        FLOATS = [Protostar::Message::FieldInfo::DOUBLE, Protostar::Message::FieldInfo::FLOAT].freeze
        private_constant :FLOATS

        # Whether every float field holding a zero holds the same zero as other's
        def __gsame_zeros?(other)
          mine = __slots
          theirs = other.__slots
          self.class.__fields.each do |info|
            kind = info.map ? info.value.kind : info.kind
            next unless FLOATS.include?(kind)
            a = mine[info.index]
            b = theirs[info.index]
            pairs = if info.map then (a || {}).map { |k, v| [v, b[k]] }
            elsif info.repeated then (a || []).zip(b || [])
            else [[a, b]]
            end
            pairs.each do |x, y|
              return false if x.is_a?(Float) && y.is_a?(Float) && x.zero? && (1.0 / x).negative? != (1.0 / y).negative?
            end
          end
          true
        end

        def initialize_copy(source)
          super
          @__gwrappers = nil
        end

        def __check_gfrozen
          raise FrozenError.new("can't modify frozen #{self.class}: #{inspect}", receiver: self) if frozen?
        end

        def __ginit(fd, value)
          info = fd.__info
          i = info.index
          if info.map
            unless value.is_a?(Hash)
              raise ArgumentError, "Expected Hash object as initializer value for map field '#{fd.name}' (given #{value.class})."
            end
            entry = fd.subtype
            key_fd = entry.lookup("key")
            value_fd = entry.lookup("value")
            hash = {}
            value.each do |k, v|
              hash[Convert.to_store(k, key_fd.type, nil, "")] = Convert.initial(v, value_fd.type, value_fd.subtype, "")
            end
            __set_slot(i, hash)
          elsif info.repeated
            unless value.is_a?(Array)
              raise ArgumentError, "Expected array as initializer value for repeated field '#{fd.name}' (given #{value.class})."
            end
            type = fd.type
            sub = fd.subtype
            name = fd.name
            __set_slot(i, value.map { |v| Convert.initial(v, type, sub, name) })
          elsif value.is_a?(Hash) && info.message?
            info.siblings&.each { |s| __set_slot(s, nil) }
            __set_slot(i, fd.subtype.msgclass.new(value))
          else
            __gset(fd, value)
          end
        end

        def method_missing(name, *args)
          if self.class.__goneof_setters.key?(name)
            raise RuntimeError, "Oneof accessors are read-only." # standard:disable Style/RedundantException
          end
          super
        end

        def respond_to_missing?(name, include_private = false)
          return false if self.class.__goneof_setters.key?(name)
          super
        end
      end

      def self.deep_copy_value(v) # :nodoc:
        case v
        when Protostar::Message then v.__gdeep_copy
        when Array then v.map { |e| e.is_a?(Protostar::Message) ? e.__gdeep_copy : e }
        when Hash then v.transform_values { |e| e.is_a?(Protostar::Message) ? e.__gdeep_copy : e }
        else v
        end
      end
    end
  end
end
