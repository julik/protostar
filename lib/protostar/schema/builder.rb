# frozen_string_literal: true

module Protostar
  module Schema
    # Turns a descriptor hash (shaped like `FileDescriptorProto#to_h`) into a
    # linked, frozen, Ractor-shareable {File}.
    #
    # It checks the shape of the hash and resolves every reference, but leaves
    # semantic validation (duplicate numbers, reserved clashes and the like) to
    # the compiler. It does not add the file to the pool.
    class Builder
      FILE_KEYS = %i[name package dependency public_dependency weak_dependency option_dependency message_type
        enum_type service extension options source_code_info syntax edition].freeze
      MESSAGE_KEYS = %i[name field extension nested_type enum_type extension_range oneof_decl options
        reserved_range reserved_name visibility].freeze
      FIELD_KEYS = %i[name number label type type_name extendee default_value oneof_index json_name options
        proto3_optional].freeze
      ONEOF_KEYS = %i[name options].freeze
      ENUM_KEYS = %i[name value options reserved_range reserved_name visibility].freeze
      ENUM_VALUE_KEYS = %i[name number options].freeze
      SERVICE_KEYS = %i[name method options].freeze
      METHOD_KEYS = %i[name input_type output_type options client_streaming server_streaming].freeze
      RANGE_KEYS = %i[start end options].freeze
      RESERVED_RANGE_KEYS = %i[start end].freeze

      SYNTAXES = {nil => :proto2, "proto2" => :proto2, "proto3" => :proto3, "editions" => :editions}.freeze
      TYPED = %i[TYPE_MESSAGE TYPE_GROUP TYPE_ENUM].freeze

      # @param hash [Hash] a FileDescriptorProto hash
      # @param pool [Pool] where the file's dependencies are looked up
      # @return [File] frozen and shareable
      # @raise [Error, ResolveError]
      def self.build(hash, pool:)
        new(hash, pool).build
      end

      # The JSON name protoc derives from a field name: underscores dropped,
      # the letter after each one upper-cased
      # @param name [String]
      # @return [String]
      def self.json_name(name)
        Schema.json_name(name)
      end

      # @api private
      def initialize(hash, pool)
        raise Error, "a FileDescriptorProto must be a Hash, got #{hash.class}" unless hash.is_a?(Hash)
        @hash = hash
        @pool = pool
      end

      # @api private
      def build
        h = @hash
        check_keys(h, FILE_KEYS, "FileDescriptorProto")
        name = string!(h, :name, "FileDescriptorProto")
        @context = name
        dependencies = strings(h, :dependency)
        proto_syntax = string(h, :syntax)
        raise Error, "#{@context}: unknown syntax #{proto_syntax.inspect}" unless SYNTAXES.key?(proto_syntax)
        edition = h[:edition]
        edition = Features::EDITION_NAMES.fetch(edition, edition) if edition.is_a?(Integer)
        if edition && !edition.is_a?(Integer) && !Features::EDITIONS.key?(edition)
          raise Error, "#{@context}: unknown edition #{edition.inspect}"
        end
        draft = File.draft(name, package: string(h, :package), syntax: proto_syntax&.to_sym, edition: edition,
          dependencies: dependencies, public_dependencies: dependency_indexes(h, :public_dependency, dependencies),
          weak_dependencies: dependency_indexes(h, :weak_dependency, dependencies),
          option_dependencies: strings(h, :option_dependency), options: options(h))
        if (info = h[:source_code_info])
          raise Error, "source_code_info must be a Hash, got #{info.class}" unless info.is_a?(Hash)
          draft.source_info = (info[:location] || []).map do |loc|
            SourceInfo::Location.new(path: loc[:path] || [], span: loc[:span] || [],
              leading_comments: loc[:leading_comments], trailing_comments: loc[:trailing_comments],
              leading_detached_comments: loc[:leading_detached_comments] || [])
          end
        end
        each_entry(h, :message_type) { |m, _| build_message(draft, m) }
        each_entry(h, :enum_type) { |e, _| build_enum(draft, e) }
        each_entry(h, :service) { |s, _| build_service(draft, s) }
        each_entry(h, :extension) { |f, _| build_field(draft, f, extension: true) }
        draft.resolve(@pool).freeze!
      end

      private

      def build_message(scope, h)
        check_keys(h, MESSAGE_KEYS, "DescriptorProto")
        name = string!(h, :name, "DescriptorProto")
        scope.message(name, visibility: h[:visibility], options: options(h)) do |m|
          oneofs = each_entry(h, :oneof_decl) do |o, _|
            check_keys(o, ONEOF_KEYS, "OneofDescriptorProto")
            m.oneof(string!(o, :name, "OneofDescriptorProto"), options: options(o))
          end
          each_entry(h, :field) { |f, _| build_field(m, f, extension: false, oneofs: oneofs) }
          each_entry(h, :nested_type) { |n, _| build_message(m, n) }
          each_entry(h, :enum_type) { |e, _| build_enum(m, e) }
          each_entry(h, :extension) { |f, _| build_field(m, f, extension: true) }
          each_entry(h, :extension_range) do |r, _|
            check_keys(r, RANGE_KEYS, "ExtensionRange")
            m.extension_range(range(r, 1), options: options(r))
          end
          ranges(h, :reserved_range, RESERVED_RANGE_KEYS, 1).each { |r| m.reserved(r) }
          m.reserved(*strings(h, :reserved_name))
        end
      end

      def build_field(scope, h, extension:, oneofs: nil)
        check_keys(h, FIELD_KEYS, "FieldDescriptorProto")
        name = string!(h, :name, "FieldDescriptorProto")
        full_name = (scope.scope_name.empty? ? name : "#{scope.scope_name}.#{name}")
        number = h[:number]
        raise Error, "#{@context}: #{full_name} has no integer number" unless number.is_a?(Integer)
        label = h[:label] || :LABEL_OPTIONAL
        raise Error, "#{@context}: #{full_name} has unknown label #{label.inspect}" unless Field::LABELS.key?(label)
        type = h[:type]
        if type && !Field::TYPES.key?(type)
          raise Error, "#{@context}: #{full_name} has unknown type #{type.inspect}"
        end
        type_name = string(h, :type_name)
        if type_name.nil? && (type.nil? || TYPED.include?(type))
          raise Error, "#{@context}: #{full_name} needs a type_name"
        elsif type_name && type && !TYPED.include?(type)
          raise Error, "#{@context}: #{full_name} is a #{type} and cannot have a type_name"
        end
        extendee = string(h, :extendee)
        if extension && extendee.nil?
          raise Error, "#{@context}: extension #{full_name} has no extendee"
        elsif !extension && extendee
          raise Error, "#{@context}: field #{full_name} has an extendee but is not an extension"
        end
        oneof = nil
        if (oneof_index = h[:oneof_index])
          oneof = !extension && oneof_index.is_a?(Integer) && oneof_index >= 0 && oneofs[oneof_index]
          raise Error, "#{@context}: #{full_name} has an invalid oneof_index #{oneof_index.inspect}" unless oneof
        end
        kwargs = {label: Field::LABELS.fetch(label), default: string(h, :default_value),
                  json_name: string(h, :json_name), optional: h[:proto3_optional] == true, options: options(h)}
        type &&= Field::TYPES.fetch(type)
        if extension
          scope.extension(name, number, type, type_name, extendee: extendee, **kwargs)
        else
          scope.field(name, number, type, type_name, oneof: oneof, **kwargs)
        end
      end

      def build_enum(scope, h)
        check_keys(h, ENUM_KEYS, "EnumDescriptorProto")
        name = string!(h, :name, "EnumDescriptorProto")
        scope.enum(name, visibility: h[:visibility], options: options(h)) do |e|
          each_entry(h, :value) do |v, _|
            check_keys(v, ENUM_VALUE_KEYS, "EnumValueDescriptorProto")
            value_name = string!(v, :name, "EnumValueDescriptorProto")
            number = v[:number]
            raise Error, "#{@context}: enum value #{value_name} has no integer number" unless number.is_a?(Integer)
            e.value(value_name, number, options: options(v))
          end
          ranges(h, :reserved_range, RESERVED_RANGE_KEYS, 0).each { |r| e.reserved(r) }
          e.reserved(*strings(h, :reserved_name))
        end
      end

      def build_service(draft, h)
        check_keys(h, SERVICE_KEYS, "ServiceDescriptorProto")
        name = string!(h, :name, "ServiceDescriptorProto")
        draft.service(name, options: options(h)) do |s|
          each_entry(h, :method) do |m, _|
            check_keys(m, METHOD_KEYS, "MethodDescriptorProto")
            s.rpc(string!(m, :name, "MethodDescriptorProto"), string!(m, :input_type, "MethodDescriptorProto"),
              string!(m, :output_type, "MethodDescriptorProto"), client_streaming: m[:client_streaming] == true,
              server_streaming: m[:server_streaming] == true, options: options(m))
          end
        end
      end

      def check_keys(h, allowed, what)
        raise Error, "#{@context}: a #{what} must be a Hash, got #{h.class}" unless h.is_a?(Hash)
        h.each_key do |key|
          next if allowed.include?(key)
          raise Error, "#{@context}: unknown key #{key.inspect} in #{what} #{h[:name].inspect}"
        end
      end

      def string(h, key)
        value = h[key]
        return nil if value.nil?
        raise Error, "#{@context}: #{key} must be a String, got #{value.inspect}" unless value.is_a?(String)
        -value
      end

      def string!(h, key, what)
        string(h, key) || raise(Error, "#{@context}: #{what} without a #{key}: #{h.inspect[0, 200]}")
      end

      def strings(h, key)
        list = array(h, key)
        return Freezer::EMPTY_ARRAY if list.empty?
        list.map do |s|
          raise Error, "#{@context}: #{key} must hold Strings, got #{s.inspect}" unless s.is_a?(String)
          -s
        end.freeze
      end

      def array(h, key)
        value = h[key]
        return Freezer::EMPTY_ARRAY if value.nil?
        raise Error, "#{@context}: #{key} must be an Array, got #{value.class}" unless value.is_a?(Array)
        value
      end

      def each_entry(h, key, &block)
        list = array(h, key)
        return Freezer::EMPTY_ARRAY if list.empty?
        list.each_with_index.map(&block).freeze
      end

      def dependency_indexes(h, key, dependencies)
        indexes = array(h, key)
        indexes.each do |i|
          next if i.is_a?(Integer) && i >= 0 && i < dependencies.size
          raise Error, "#{@context}: #{key} #{i.inspect} is not an index into dependency"
        end
        indexes.empty? ? Freezer::EMPTY_ARRAY : indexes.dup.freeze
      end

      # `end_offset` is 1 where descriptor.proto makes `end` exclusive, 0 where inclusive
      def ranges(h, key, keys, end_offset)
        each_entry(h, key) do |r, _|
          check_keys(r, keys, key.to_s)
          range(r, end_offset)
        end
      end

      def range(r, end_offset)
        first = r[:start]
        last = r[:end]
        unless first.is_a?(Integer) && last.is_a?(Integer)
          raise Error, "#{@context}: a range needs integer start and end, got #{r.inspect}"
        end
        first..(last - end_offset)
      end

      def options(h)
        return nil unless h.key?(:options) && !h[:options].nil?
        raw = h[:options]
        raise Error, "#{@context}: options must be a Hash, got #{raw.class}" unless raw.is_a?(Hash)
        raw
      end
    end
  end
end
