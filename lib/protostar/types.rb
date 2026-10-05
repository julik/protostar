# frozen_string_literal: true

module Protostar
  # Defines message classes and enum modules from descriptors, and keeps a
  # registry of them by full name.
  #
  #   types = Protostar::Types.define(schema_file)
  #   Person = types.fetch("acme.Person")
  #   Protostar::Types.find("acme.Person") # => Person
  #
  # The registry is a process-wide object guarded by a Mutex and is meant to be
  # used from the main Ractor. The classes and modules it hands out can be used
  # from any Ractor.
  module Types
    # A set of defined types, by full name, and the files they came from
    class Registry
      # @param open_enums [Boolean] treat every enum as open: numbers without a
      #   name are kept in the field on decode and accepted on assignment, as
      #   google-protobuf's Ruby gem does, instead of going to unknown fields
      def initialize(open_enums: false)
        @open_enums = open_enums
        @mutex = Mutex.new
        @types = {}
        @files = {}
      end

      # @param full_name [String] without a leading dot
      # @return [Class, Module, nil]
      def find(full_name)
        @mutex.synchronize { @types[full_name] }
      end

      # @param file_name [String]
      # @return [Hash{String => Class, Module}, nil] what {#define} returned for the file
      def file(file_name)
        @mutex.synchronize { @files[file_name]&.last }
      end

      # Defines every message and enum of a file. The file's dependencies must
      # have been defined first. Defining the same {Schema::File} again returns
      # the types made the first time.
      # @param file [Schema::File]
      # @param name [Module, nil] a namespace: when given, top-level types
      #   become its constants and nested types constants of their parent class
      # @return [Hash{String => Class, Module}] frozen, full name to class or module
      # @raise [Error] for an undefined dependency or a name already defined from another file
      def define(file, name: nil)
        @mutex.synchronize do
          if (defined = @files[file.name])
            return defined.last if defined.first.equal?(file)
            raise Error, "file \"#{file.name}\" is already defined from another descriptor"
          end
          types = Definer.new(file, @types, open_enums: @open_enums).define
          types.each_key do |full_name|
            raise Error, "\"#{full_name}\" is already defined by \"#{@types[full_name].descriptor.file.name}\"" if @types.key?(full_name)
          end
          Types.assign_constants(file, types, name) if name
          types.each_value { |t| t.freeze if t.is_a?(Module) && !t.is_a?(Class) }
          @types.merge!(types)
          @files[file.name] = [file, types]
          types
        end
      end
    end

    @registry = Registry.new

    class << self
      # @return [Registry] the process-wide registry
      attr_reader :registry

      # @see Registry#define
      def define(file, name: nil, registry: @registry)
        registry.define(file, name: name)
      end

      # @see Registry#find
      def find(full_name, registry: @registry)
        registry.find(full_name)
      end

      # @api private
      def assign_constants(file, types, namespace)
        place = lambda do |descriptor, owner|
          const = Enum.constant_name(descriptor.name)
          type = types[descriptor.full_name]
          return unless const && type
          owner.const_set(const, type) unless owner.const_defined?(const, false)
          return unless descriptor.is_a?(Schema::Message)
          descriptor.nested_messages.each { |m| place.call(m, type) }
          descriptor.nested_enums.each { |e| place.call(e, type) }
        end
        file.messages.each { |m| place.call(m, namespace) }
        file.enums.each { |e| place.call(e, namespace) }
      end
    end

    # Makes the classes and modules of one file
    # @api private
    class Definer
      def initialize(file, known, open_enums: false)
        @file = file
        @known = known
        @open_enums = open_enums
        @types = {}
        @reserved = Message::Accessors.reserved
      end

      def define
        messages = @file.all_messages.reject(&:map_entry?)
        @file.all_enums.each { |e| @types[e.full_name] = Enum.build(e) }
        messages.each { |m| @types[m.full_name] = Class.new(Message) }
        messages.each { |m| setup(@types[m.full_name], m) }
        @types.freeze
      end

      private

      # Names end up inside class_eval'd source, so anything a .proto could not spell is refused
      IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      def setup(klass, descriptor)
        (descriptor.fields.map(&:name) + descriptor.real_oneofs.map(&:name)).each do |n|
          raise Protostar::Error, "#{descriptor.full_name} has a name that is not an identifier: #{n.inspect}" unless IDENTIFIER.match?(n)
        end
        oneof_slots = descriptor.real_oneofs.to_h do |o|
          [o, o.fields.map { |f| descriptor.fields.index(f) }]
        end
        classes = method(:resolve)
        fields = descriptor.fields.each_with_index.map do |f, i|
          slots = oneof_slots[f.real_oneof] if f.real_oneof
          Message::FieldInfo.new(f, i, classes, siblings: slots && (slots - [i]), open_enums: @open_enums)
        end
        oneofs = oneof_slots.map { |o, slots| [o.name.to_sym, slots] }
        klass.__define(descriptor: descriptor, fields: fields, oneofs: oneofs)
        Message::Accessors.install(klass, fields, oneofs, @reserved)
        Codec::DecodeGenerator.install(klass, fields)
        Codec::EncodeGenerator.install(klass, fields)
        well_known = WellKnown::MIXINS[descriptor.full_name]
        klass.include(well_known) if well_known
      end

      def resolve(descriptor)
        @types[descriptor.full_name] || @known[descriptor.full_name] ||
          raise(Error, "#{descriptor.full_name} comes from \"#{descriptor.file.name}\", which must be " \
            "defined before \"#{@file.name}\"")
      end
    end
  end
end
