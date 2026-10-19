# frozen_string_literal: true

module Protostar
  class Message
    # Reading and writing a message class's fields by descriptor, name or
    # number rather than through the accessors, for code that walks messages
    # it does not know in advance: serializers, builders, form mappers.
    # Every message class has one, made when the class is defined, frozen and
    # shareable:
    #
    # ```ruby
    # r = Acme::Person.reflection
    # r.fields.map(&:name)                 # => ["name", "id", "emails", "address"]
    # r.get(person, :name)                 # => "Ada"
    # r.set(person, "id", 7)
    # r.set?(person, :address)             # => false
    # r.message_class(:address)            # => Acme::Address
    # r.each(person) { |field, value| ... } # fields that are set, in declaration order
    # ```
    #
    # It lives on the class (`Klass.reflection`), where no field accessor can
    # take its name. Values go through the same coercion and checks as the
    # accessors: `set(m, f, v)` is `m.f = v`, `get(m, f)` is `m.f`.
    class Reflection
      # The message class it reflects.
      attr_reader :klass #: untyped
      attr_reader :descriptor #: Schema::Message

      def initialize(klass, descriptor) # :nodoc:
        @klass = klass
        @descriptor = descriptor
        @by_number = klass.__by_number
        @by_name = klass.__by_name
      end

      # Returns them in declaration order.
      #: () -> Array[untyped]
      def fields
        @descriptor.fields
      end

      # Returns real oneofs; a proto3 `optional` field's
      # synthetic oneof is left out, as it is no choice.
      #: () -> Array[untyped]
      def oneofs
        @descriptor.real_oneofs
      end

      # - `key`: a field, its name or its number
      #: (field_key key) -> untyped
      def field(key)
        info(key)&.descriptor
      end

      # - `message`: an instance of the class
      #
      # Returns what the field's reader returns.
      # Raises ArgumentError when there is no such field.
      #: (Message message, field_key key) -> untyped
      def get(message, key)
        message.__get(info!(key))
      end

      # - `value`: nil clears the field
      #
      # Raises ArgumentError when there is no such field.
      # Raises Protostar::TypeError for a value the field cannot hold.
      #: (Message message, field_key key, untyped value) -> Message
      def set(message, key, value)
        message.__set(info!(key).index, value)
        message
      end

      # Returns set, for a field with presence; not empty, for a
      # repeated or map field; not its zero value, for any other.
      #: (Message message, field_key key) -> bool
      def set?(message, key)
        info = info!(key)
        v = message.__values[info.index]
        return false if v.nil?
        return !v.empty? if info.repeated || info.map
        info.presence || !info.zero?(v)
      end

      #: (Message message, field_key key) -> Message
      def clear(message, key)
        message.__set(info!(key).index, nil)
        message
      end

      # Returns the member that is set.
      #: (Message message, untyped oneof) -> untyped
      def which(message, oneof)
        oneof = @descriptor.oneofs.find { |o| o.name == oneof.to_s } unless oneof.is_a?(Schema::Oneof)
        raise ArgumentError, "#{@descriptor.full_name} has no oneof #{oneof.inspect}" unless oneof
        oneof.fields.find { |f| !message.__values[@by_number.fetch(f.number).index].nil? }
      end

      # - `key`: a message or group field,
      #   or a map field whose values are messages
      #
      # Returns the class its values are instances of.
      #: (field_key key) -> untyped
      def message_class(key)
        info = info!(key)
        info.map ? info.value.message_class : info.message_class
      end

      # - `key`: an enum field, or a map field of enum values
      #
      # Returns the enum's module.
      #: (field_key key) -> untyped
      def enum_module(key)
        info = info!(key)
        info.map ? info.value.enum_module : info.enum_module
      end

      # Yields each field that is #set?, in declaration order
      #
      # - yields `value`: what the reader returns
      #
      # Returns an Enumerator without a block.
      #: (Message message) { (untyped field, untyped value) -> void } -> nil
      #: (Message message) -> Enumerator[[ untyped, untyped ], nil]
      def each(message)
        return enum_for(:each, message) unless block_given?
        @klass.__fields.each do |info|
          next unless set?(message, info.descriptor)
          yield info.descriptor, message.__get(info)
        end
        nil
      end

      #: () -> String
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
