# frozen_string_literal: true

module Google
  module Protobuf
    module Internal
      # Turns a class protostar's registry made into a google-protobuf
      # message class: the gem's class and instance methods are mixed in,
      # and the field accessors are defined in a module prepended to the class.
      # @api private
      module MessageClass
        module_function

        # @param klass [Class] a subclass of Protostar::Message
        # @param descriptor [Descriptor]
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
          klass.include(MessageExts)
          klass.include(MessageMethods)
          klass.extend(MessageExts::ClassMethods)
          klass.extend(ClassMethods)
          accessors = Module.new
          taken = reserved.dup
          plan.each { |fd| define_field(accessors, fd, taken) }
          oneofs.each { |o| define_oneof(accessors, o, taken) }
          klass.prepend(accessors)
        end

        # Methods a message already has; a field named like one is reached through [] and []=
        def reserved
          @reserved ||= (Object.public_instance_methods + Protostar::Message.public_instance_methods +
            MessageExts.public_instance_methods + MessageMethods.public_instance_methods + %i[initialize])
            .to_h { |m| [m, true] }.freeze
        end

        def define_field(mod, fd, taken)
          info = fd.__info
          i = info.index
          name = fd.name
          claim = ->(method) { !taken[method] && (taken[method] = true) }
          if claim.call(name.to_sym)
            if info.map
              mod.define_method(name) { __gmap(fd) }
            elsif info.repeated
              mod.define_method(name) { __grepeated(fd) }
            elsif info.presence && !info.message?
              default = info.default
              mod.define_method(name) do
                v = @values[i]
                v.nil? ? default : v
              end
            else
              mod.define_method(name) { @values[i] }
            end
          end
          mod.define_method(:"#{name}=") { |v| __gset(fd, v) } if claim.call(:"#{name}=")
          mod.define_method(:"clear_#{name}") { __gclear(fd) } if claim.call(:"clear_#{name}")
          mod.define_method(:"has_#{name}?") { !@values[i].nil? } if info.presence && claim.call(:"has_#{name}?")
          if fd.type == :enum && claim.call(:"#{name}_const")
            if info.repeated
              mod.define_method(:"#{name}_const") { __grepeated(fd).map { |v| fd.subtype.__numbers.fetch(v, v) } }
            else
              mod.define_method(:"#{name}_const") do
                v = @values[i]
                v = info.default if v.nil?
                fd.subtype.__numbers.fetch(v, v)
              end
            end
          end
          return unless !info.repeated && fd.wrapper?
          mod.define_method(:"#{name}_as_value") { @values[i]&.value } if claim.call(:"#{name}_as_value")
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
              fields.each { |slot, member| return member unless @values[slot].nil? }
              nil
            end
          end
          if !taken[:"clear_#{name}"] && (taken[:"clear_#{name}"] = true)
            mod.define_method(:"clear_#{name}") do
              __check_gfrozen
              fields.each { |slot, _| @values[slot] = nil }
              nil
            end
          end
          if !taken[:"has_#{name}?"] && (taken[:"has_#{name}?"] = true)
            mod.define_method(:"has_#{name}?") { fields.any? { |slot, _| !@values[slot].nil? } }
          end
        end
      end

      # Class methods of every message class
      # @api private
      module ClassMethods
        # @return [Descriptor]
        def descriptor
          @__gdescriptor
        end

        # @api private
        attr_reader :__gplan, :__gnames, :__goneof_setters

        # @param data [String] protobuf wire format
        # @param options [Hash] `recursion_limit:` how deep messages may nest (default 100)
        # @return [Message]
        # @raise [ParseError]
        def decode(data, options = {})
          raise ArgumentError, "Expected hash arguments." unless options.is_a?(Hash)
          raise ArgumentError, "Expected string for binary protobuf data." unless data.is_a?(String)
          limit = options[:recursion_limit]
          limit = limit.is_a?(Numeric) ? limit.to_i : Protostar::Codec::Decoder::RECURSION_LIMIT
          Protostar::Codec::Decoder.decode(self, data, recursion_limit: limit)
        rescue Protostar::DecodeError
          raise ParseError, "Error occurred during parsing"
        end

        # @param message [Message] an instance of this class
        # @param options [Hash] `recursion_limit:` how deep messages may nest (default 100)
        # @return [String] binary, frozen
        def encode(message, options = {})
          raise ArgumentError, "Message of wrong type." unless message.is_a?(self)
          raise ArgumentError, "Expected hash arguments." unless options.is_a?(Hash)
          limit = options[:recursion_limit]
          limit = limit.is_a?(Numeric) ? limit.to_i : Protostar::Codec::Decoder::RECURSION_LIMIT
          raise "Exceeded maximum depth (possibly cycle)" if message.__gdepth(limit + 1) > limit
          Protostar::Codec::Encoder.encode(message).freeze
        rescue Protostar::EncodeError => e
          raise TypeError, e.message
        end

        # @param data [String] JSON
        # @param options [Hash] `ignore_unknown_fields:`
        # @return [Message]
        # @raise [ParseError]
        def decode_json(data, options = {})
          options = Internal.options_hash(options)
          raise ArgumentError, "Expected string for JSON data." unless data.is_a?(String)
          Internal::Json.decode(self, data, options)
        end

        # @param message [Message] an instance of this class
        # @param options [Hash] `preserve_proto_fieldnames:`, `emit_defaults:`, `format_enums_as_integers:`
        # @return [String] UTF-8, frozen
        def encode_json(message, options = {})
          options = Internal.options_hash(options)
          raise ArgumentError, "Message of wrong type." unless message.is_a?(self)
          Internal::Json.encode(message, options)
        end

        # @api private
        def __gpool
          @__gdescriptor.descriptor_pool
        end
      end

      # The options Hash the gem's methods take, from a Hash or anything with to_h
      # @api private
      def self.options_hash(options)
        return options if options.is_a?(Hash)
        return options.to_h if options.respond_to?(:to_h)
        raise ArgumentError, "Expected hash arguments"
      end

      # Instance methods of every message class
      # @api private
      module MessageMethods
        # @param initial_value [Hash, nil] field names (Strings or Symbols) to values;
        #   Hashes become messages, Arrays repeated fields, Hashes map fields
        # @raise [ArgumentError] for a name that is not a field
        def initialize(initial_value = nil)
          super()
          return if initial_value.nil?
          raise ArgumentError, "Expected hash arguments." unless initial_value.is_a?(Hash)
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

        # @param name [String]
        # @return [Object, nil] the field's value; nil when there is no such field
        def [](name)
          raise TypeError, "Expected String for name but got #{name.class}" unless name.is_a?(String)
          fd = self.class.__gnames[name]
          fd && __gget(fd)
        end

        # @param name [String]
        # @raise [ArgumentError] when there is no such field
        def []=(name, value)
          raise TypeError, "Expected String for name but got #{name.class}" unless name.is_a?(String)
          fd = self.class.__gnames[name]
          raise ArgumentError, "Unknown field: #{name}" unless fd
          __gset(fd, value)
        end

        # @return [Hash] Symbol keys; fields with presence when set, others
        #   when not at their default; nested messages as Hashes
        def to_h
          __to_h
        end

        def inspect
          parts = []
          values = @values
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
          "<#{self.class.name || self.class.descriptor.name}: #{parts.join(", ")}>"
        end

        def to_s
          inspect
        end

        def pretty_print(q)
          q.text(inspect)
        end

        # Same class and the same field values, extensions included
        def ==(other)
          return true if equal?(other)
          return false unless other.instance_of?(self.class)
          super && __gextensions == other.__gextensions
        end

        def eql?(other)
          self == other
        end

        def hash
          super
        end

        # A shallow copy: nested messages are shared, containers are not
        def dup
          copy = self.class.allocate
          copy.__gcopy_from(self)
          copy
        end

        def clone
          dup
        end

        # @api private
        def __gcopy_from(source)
          @values = source.__values.map { |v| (v.is_a?(Array) || v.is_a?(Hash)) ? v.dup : v }
          @unknown = source.unknown_fields.empty? ? nil : source.unknown_fields.dup.freeze
          @__gwrappers = nil
        end

        # @api private
        # @return [Message] a copy with every nested message copied too
        def __gdeep_copy
          copy = self.class.allocate
          copy.__gdeep_from(self)
          copy
        end

        # @api private
        def __gdeep_from(source)
          @values = source.__values.map { |v| Internal.deep_copy_value(v) }
          @unknown = source.unknown_fields.empty? ? nil : source.unknown_fields.dup.freeze
          @__gwrappers = nil
        end

        # @api private
        # @param fd [FieldDescriptor]
        def __gget(fd)
          return __gext_get(fd) if fd.__extension?
          info = fd.__info
          if info.map
            __gmap(fd)
          elsif info.repeated
            __grepeated(fd)
          else
            v = @values[info.index]
            (v.nil? && !info.message?) ? info.default : v
          end
        end

        # @api private
        def __ghas?(fd)
          return __gext_has?(fd) if fd.__extension?
          !@values[fd.__info.index].nil?
        end

        # @api private
        def __gset(fd, value)
          __check_gfrozen
          return __gext_set(fd, value) if fd.__extension?
          info = fd.__info
          i = info.index
          if info.map
            raise TypeError, "Expected Map instance" unless value.is_a?(Map)
            value.__check_field(fd)
            @values[i] = value.__hash
            (@__gwrappers ||= {})[i] = value
          elsif info.repeated
            raise TypeError, "Expected repeated field array" unless value.is_a?(RepeatedField)
            value.__check_field(fd)
            @values[i] = value.__array
            (@__gwrappers ||= {})[i] = value
          elsif value.nil? && (info.message? || info.siblings)
            @values[i] = nil
          else
            v = Convert.to_store(value, fd.type, fd.subtype, fd.name)
            info.siblings&.each { |s| @values[s] = nil }
            @values[i] = v
          end
          value
        end

        # @api private
        def __gclear(fd)
          __check_gfrozen
          return __gext_clear(fd) if fd.__extension?
          info = fd.__info
          @values[info.index] = (info.presence || info.repeated || info.map) ? nil : info.default
          nil
        end

        # @api private
        # @return [RepeatedField] the field's, the same object while the field holds the same Array
        def __grepeated(fd)
          i = fd.__info.index
          array = @values[i]
          wrapper = @__gwrappers&.[](i)
          return wrapper if wrapper && array && wrapper.__array.equal?(array)
          if array.nil?
            return RepeatedField.__for_field(fd, [].freeze).freeze if frozen?
            array = @values[i] = []
          end
          wrapper = RepeatedField.__for_field(fd, array)
          if frozen?
            wrapper.freeze
          else
            (@__gwrappers ||= {})[i] = wrapper
          end
          wrapper
        end

        # @api private
        # @return [Map] the field's, the same object while the field holds the same Hash
        def __gmap(fd)
          i = fd.__info.index
          hash = @values[i]
          wrapper = @__gwrappers&.[](i)
          return wrapper if wrapper && hash && wrapper.__hash.equal?(hash)
          if hash.nil?
            return Map.__for_field(fd, {}.freeze).freeze if frozen?
            hash = @values[i] = {}
          end
          wrapper = Map.__for_field(fd, hash)
          if frozen?
            wrapper.freeze
          else
            (@__gwrappers ||= {})[i] = wrapper
          end
          wrapper
        end

        # @api private
        # @return [Integer] how deeply messages nest under this one, counting it; stops at `limit`
        def __gdepth(limit)
          return 1 if limit <= 1
          deepest = 0
          self.class.__fields.each do |info|
            next unless info.message? || (info.map && info.value.message?)
            v = @values[info.index]
            next if v.nil?
            each_message = if info.map then v.each_value
            elsif info.repeated then v.each
            else [v].each
            end
            each_message.each do |m|
              d = m.__gdepth(limit - 1)
              deepest = d if d > deepest
              return limit if deepest + 1 >= limit
            end
          end
          deepest + 1
        end

        # @api private
        # @return [Array<UnknownField>] the unknown fields holding extensions, for comparison
        def __gextensions
          descriptor = self.class.descriptor.__schema
          return Protostar::Message::EMPTY_ARRAY if descriptor.extension_ranges.empty?
          unknown_fields.sort_by(&:number).map(&:to_wire)
        end

        private

        def initialize_copy(source)
          super
          @__gwrappers = nil
        end

        def __check_gfrozen
          raise FrozenError.new("can't modify frozen #{self.class}", receiver: self) if frozen?
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
              hash[Convert.to_store(k, key_fd.type, nil, fd.name)] = Convert.initial(v, value_fd.type, value_fd.subtype, fd.name)
            end
            @values[i] = hash
          elsif info.repeated
            unless value.is_a?(Array)
              raise ArgumentError, "Expected array as initializer value for repeated field '#{fd.name}' (given #{value.class})."
            end
            type = fd.type
            sub = fd.subtype
            name = fd.name
            @values[i] = value.map { |v| Convert.initial(v, type, sub, name) }
          elsif value.is_a?(Hash) && info.message?
            info.siblings&.each { |s| @values[s] = nil }
            @values[i] = fd.subtype.msgclass.new(value)
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

      # @api private
      def self.deep_copy_value(v)
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
