# frozen_string_literal: true

module Protostar
  class Message
    # Reading and writing a message class's fields by descriptor, name or
    # number rather than through the accessors, for code that walks messages
    # it does not know in advance: serializers, builders, form mappers.
    # Every message class has one, made when the class is defined, frozen and
    # shareable:
    #
    #   r = Acme::Person.reflection
    #   r.fields.map(&:name)                 # => ["name", "id", "emails", "address"]
    #   r.get(person, :name)                 # => "Ada"
    #   r.set(person, "id", 7)
    #   r.set?(person, :address)             # => false
    #   r.message_class(:address)            # => Acme::Address
    #   r.each(person) { |field, value| ... } # fields that are set, in declaration order
    #
    # It lives on the class (`Klass.reflection`), where no field accessor can
    # take its name. Values go through the same coercion and checks as the
    # accessors: `set(m, f, v)` is `m.f = v`, `get(m, f)` is `m.f`.
    class Reflection
      # @return [Class] the message class it reflects
      attr_reader :klass
      # @return [Schema::Message]
      attr_reader :descriptor

      # @api private
      def initialize(klass, descriptor)
        @klass = klass
        @descriptor = descriptor
        @by_number = klass.__by_number
        @by_name = klass.__by_name
      end

      # @return [Array<Schema::Field>] in declaration order
      def fields
        @descriptor.fields
      end

      # @return [Array<Schema::Oneof>] real oneofs; a proto3 `optional` field's
      #   synthetic oneof is left out, as it is no choice
      def oneofs
        @descriptor.real_oneofs
      end

      # @param key [Schema::Field, String, Symbol, Integer] a field, its name or its number
      # @return [Schema::Field, nil]
      def field(key)
        info(key)&.descriptor
      end

      # @param message [Message] an instance of the class
      # @param key [Schema::Field, String, Symbol, Integer]
      # @return [Object] what the field's reader returns
      # @raise [ArgumentError] when there is no such field
      def get(message, key)
        message.__get(info!(key))
      end

      # @param message [Message]
      # @param key [Schema::Field, String, Symbol, Integer]
      # @param value [Object] nil clears the field
      # @raise [ArgumentError] when there is no such field
      # @raise [Protostar::TypeError] for a value the field cannot hold
      def set(message, key, value)
        message.__set(info!(key).index, value)
        message
      end

      # @param message [Message]
      # @param key [Schema::Field, String, Symbol, Integer]
      # @return [Boolean] set, for a field with presence; not empty, for a
      #   repeated or map field; not its zero value, for any other
      def set?(message, key)
        info = info!(key)
        v = message.__values[info.index]
        return false if v.nil?
        return !v.empty? if info.repeated || info.map
        info.presence || !info.zero?(v)
      end

      # @param message [Message]
      # @param key [Schema::Field, String, Symbol, Integer]
      def clear(message, key)
        message.__set(info!(key).index, nil)
        message
      end

      # @param message [Message]
      # @param oneof [Schema::Oneof, String, Symbol]
      # @return [Schema::Field, nil] the member that is set
      def which(message, oneof)
        oneof = @descriptor.oneofs.find { |o| o.name == oneof.to_s } unless oneof.is_a?(Schema::Oneof)
        raise ArgumentError, "#{@descriptor.full_name} has no oneof #{oneof.inspect}" unless oneof
        oneof.fields.find { |f| !message.__values[@by_number.fetch(f.number).index].nil? }
      end

      # @param key [Schema::Field, String, Symbol, Integer] a message or group field,
      #   or a map field whose values are messages
      # @return [Class, nil] the class its values are instances of
      def message_class(key)
        info = info!(key)
        info.map ? info.value.message_class : info.message_class
      end

      # @param key [Schema::Field, String, Symbol, Integer] an enum field, or a map field of enum values
      # @return [Module, nil] the enum's module
      def enum_module(key)
        info = info!(key)
        info.map ? info.value.enum_module : info.enum_module
      end

      # Yields each field that is {#set?}, in declaration order
      # @param message [Message]
      # @yieldparam field [Schema::Field]
      # @yieldparam value [Object] what the reader returns
      # @return [Enumerator] without a block
      def each(message)
        return enum_for(:each, message) unless block_given?
        @klass.__fields.each do |info|
          next unless set?(message, info.descriptor)
          yield info.descriptor, message.__get(info)
        end
        nil
      end

      def inspect
        "#<#{self.class.name} #{@descriptor.full_name}>"
      end

      private

      def info(key)
        case key
        when Integer then @by_number[key]
        when Schema::Field
          found = @by_number[key.number]
          found if found&.descriptor.equal?(key)
        else @by_name[key]
        end
      end

      def info!(key)
        info(key) || raise(ArgumentError, "#{@descriptor.full_name} has no field #{key.inspect}")
      end
    end
  end
end
