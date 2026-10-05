# frozen_string_literal: true

module Protostar
  class Compiler
    # protoc's OptionInterpreter. Each `option` statement becomes an entry
    # `[field, value]` (`value` is itself a list of entries for message
    # fields), accumulated per element the way protoc accumulates unknown
    # fields, so "already set" checks and the merging of `(a).b = 1` with
    # `(a).c = 2` behave as in protoc. The entries are then folded into the
    # options hash: options message fields by name, extensions under
    # `:__extensions` by full name.
    #
    # Option types are read from built descriptors: those in the pool, and
    # for the file being linked a structural build of it without options, so
    # options declared and used in the same file (descriptor.proto's own
    # included) resolve the same way.
    #
    # @api private
    class OptionInterpreter
      INT32_RANGE = (-2**31..2**31 - 1)
      INT64_RANGE = (-2**63..2**63 - 1)
      UINT32_MAX = 2**32 - 1
      UINT64_MAX = 2**64 - 1

      # @return [Hash{Array<Integer> => Array<Integer>}] uninterpreted_option paths to option paths
      attr_reader :interpreted_paths

      # @param linker [Linker]
      # @param pool [Schema::Pool]
      # @param fallback [#call, nil] the bundled descriptor.proto's message for a name
      def initialize(linker, pool, fallback)
        @linker = linker
        @table = linker.table
        @pool = pool
        @fallback = fallback
        @interpreted_paths = {}
        @repeated_counts = Hash.new(0)
      end

      # @param pending [Array<Linker::Pending>]
      # @return [Hash{AST::Node => Hash}] the options hash of every element that declared options
      def run(pending)
        @local = Schema::Builder.build(@linker.structural_hash, pool: @pool)
        state = pending.map { |p| [p, [], []] }
        state.each { |p, first, _| interpret(p, first, skip_extensions: true) }
        if block_given?
          features = {}.compare_by_identity
          state.each do |p, first, _|
            folded = fold(first)
            features[p.node] = folded[:features] if folded.key?(:features)
          end
          yield features
        end
        state.each { |p, first, second| interpret(p, second, skip_extensions: false, earlier: first) }
        result = {}.compare_by_identity
        state.each do |p, first, second|
          hash = p.options.known.dup
          fold(first + second, hash)
          result[p.node] = hash
        end
        result
      end

      # A Schema descriptor for a symbol table entry
      def schema_of(symbol)
        return nil if symbol.nil?
        symbol.local? ? @local.find_symbol(symbol.full_name) : symbol.object
      end

      # The options message to interpret against, protoc's choice: the pool's
      # (or this file's) when present, else the one compiled into protoc
      def options_type(name)
        found = @table.find_not_enforcing_deps(name)
        message = schema_of(found) if found&.kind == :message
        return message if message
        builtin = @fallback&.call(name)
        @builtin_file = builtin&.file
        builtin
      end

      private

      def interpret(pending, entries, skip_extensions:, earlier: nil)
        @pending = pending
        pending.options.uninterpreted.each_with_index do |option, i|
          src_path = pending.path + [999, i]
          break unless interpret_single(option, entries, src_path, skip_extensions)
        end
      end

      def name_error(option, message)
        @linker.error(option, :option_name, message)
        false
      end

      def value_error(option, message)
        @linker.error(option, :option_value, message)
        false
      end

      def interpret_single(option, entries, src_path, skip_extensions)
        if option.name.empty?
          return true if skip_extensions
          return name_error(option, "Option must have a name.")
        end
        if option.name[0][0] == "uninterpreted_option"
          return true if skip_extensions
          return name_error(option, "Option must not use reserved name \"uninterpreted_option\".")
        end
        return true if skip_extensions == option.name[0][1]

        descriptor = options_type(Linker::OPTIONS_TYPES.fetch(@pending.kind))
        field = nil
        intermediate = []
        debug = +""
        dest_path = @pending.path.dup
        option.name.each_with_index do |(part, extension), i|
          debug << "." unless debug.empty?
          unresolved = nil
          if extension
            debug << "(#{part})"
            symbol = @table.lookup(part, @pending.name_scope)
            unresolved = @table.unresolved_name
            field = (symbol&.kind == :field) ? schema_of(symbol) : nil
          else
            debug << part
            field = descriptor.fields_by_name[part]
          end

          if field.nil?
            if unresolved
              return name_error(option, "Option \"#{debug}\" is resolved to \"(#{unresolved})\", which is not defined. " \
                "The innermost scope is searched first in name resolution. Consider using a leading '.'(i.e., " \
                "\"(.#{debug[1..]}\") to start from the outermost scope.")
            end
            return name_error(option, "Option \"#{debug}\" unknown. Ensure that your proto definition file imports " \
              "the proto which defines the option (i.e. via import option after edition 2024).")
          end
          holder = field.extension? ? field.extendee : field.containing_message
          if holder.full_name != descriptor.full_name
            return name_error(option, "Option field \"#{debug}\" is not a field or extension of message " \
              "\"#{descriptor.name}\".")
          end
          dest_path << field.number
          if field.file.equal?(@local) && option.name[0] == ["features", false]
            return name_error(option, "Feature \"#{debug}\" can't be used in the same file it's defined in.")
          end
          next unless i < option.name.size - 1
          unless field.type == :message || field.type == :group
            return name_error(option, "Option \"#{debug}\" is an atomic type, not a message.")
          end
          if field.repeated?
            return name_error(option, "Option field \"#{debug}\" is a repeated message. Repeated message options " \
              "must be initialized using an aggregate value.")
          end
          intermediate << field
          descriptor = field.message_type
        end

        return false if !field.repeated? && already_set?(intermediate, field, debug, entries, option)

        value = option_value(field, option)
        return false if value.equal?(FAILED)
        entry = [field, value]
        intermediate.reverse_each { |outer| entry = [outer, [entry]] }
        entries << entry

        if field.repeated?
          key = dest_path.dup.freeze
          index = @repeated_counts[key]
          @repeated_counts[key] += 1
          dest_path << index
        end
        @interpreted_paths[src_path] = dest_path
        true
      end

      FAILED = Object.new.freeze
      private_constant :FAILED

      # ExamineIfOptionIsSet
      def already_set?(intermediate, field, debug, entries, option)
        if intermediate.empty?
          if entries.any? { |f, _| f.number == field.number }
            name_error(option, "Option \"#{debug}\" was already set.")
            return true
          end
          return false
        end
        first, *rest = intermediate
        entries.each do |f, value|
          next unless f.number == first.number && value.is_a?(Array)
          return true if already_set?(rest, field, debug, value, option)
        end
        false
      end

      def option_value(field, option)
        kind = option.value_kind
        value = option.value
        name = field.full_name
        case field.type
        when :int32, :sint32, :sfixed32
          int_option(option, kind, value, INT32_RANGE, "int32", name)
        when :int64, :sint64, :sfixed64
          if kind == :positive_int_value
            if value > INT64_RANGE.end
              value_error(option, out_of_range(INT64_RANGE, "int64", name))
              return FAILED
            end
            value
          elsif kind == :negative_int_value
            value
          else
            value_error(option, must_be_int(INT64_RANGE, "int64", name))
            FAILED
          end
        when :uint32, :fixed32
          if kind == :positive_int_value
            if value > UINT32_MAX
              value_error(option, out_of_range(0..UINT32_MAX, "uint32", name))
              return FAILED
            end
            value
          else
            value_error(option, must_be_int(0..UINT32_MAX, "uint32", name))
            FAILED
          end
        when :uint64, :fixed64
          return value if kind == :positive_int_value
          value_error(option, must_be_int(0..UINT64_MAX, "uint64", name))
          FAILED
        when :float, :double
          number = case kind
          when :double_value, :positive_int_value, :negative_int_value then value.to_f
          when :identifier_value
            if value == "inf"
              Float::INFINITY
            elsif value == "nan"
              Float::NAN
            end
          end
          if number.nil?
            value_error(option, "Value must be number for #{field.type} option \"#{name}\".")
            return FAILED
          end
          (field.type == :float) ? Schema::DefaultValue.to_float32(number) : number
        when :bool
          unless kind == :identifier_value
            value_error(option, "Value must be identifier for boolean option \"#{name}\".")
            return FAILED
          end
          case value
          when "true" then true
          when "false" then false
          else
            value_error(option, "Value must be \"true\" or \"false\" for boolean option \"#{name}\".")
            FAILED
          end
        when :enum
          unless kind == :identifier_value
            value_error(option, "Value must be identifier for enum-valued option \"#{name}\".")
            return FAILED
          end
          enum_option(field, value, option)
        when :string, :bytes
          unless kind == :string_value
            value_error(option, "Value must be quoted string for string option \"#{name}\".")
            return FAILED
          end
          (field.type == :string) ? value.dup.force_encoding(Encoding::UTF_8) : value.b
        when :message, :group
          unless kind == :aggregate_value
            value_error(option, "Option \"#{name}\" is a message. To set the entire message, use syntax like " \
              "\"#{field.name} = { <proto text format> }\". To set fields within it, use syntax like " \
              "\"#{field.name}.foo = value\".")
            return FAILED
          end
          parser = TextFormat.new(value, field.message_type, self, @table)
          entries = parser.parse
          unless entries
            value_error(option, "Error while parsing option value for \"#{field.name}\": #{parser.errors.join("; ")}")
            return FAILED
          end
          entries
        end
      end

      def int_option(option, kind, value, range, type, name)
        if kind == :positive_int_value || kind == :negative_int_value
          return value if range.cover?(value)
          value_error(option, out_of_range(range, type, name))
        else
          value_error(option, must_be_int(range, type, name))
        end
        FAILED
      end

      def out_of_range(range, type, name)
        "Value out of range, #{range.begin} to #{range.end}, for #{type} option \"#{name}\"."
      end

      def must_be_int(range, type, name)
        "Value must be integer, from #{range.begin} to #{range.end}, for #{type} option \"#{name}\"."
      end

      def enum_option(field, value_name, option)
        enum = field.enum_type
        found = nil
        if @builtin_file && enum.file.equal?(@builtin_file)
          found = enum.value(value_name)
        else
          scope = enum.full_name[0, enum.full_name.size - enum.name.size]
          symbol = @table.find_not_enforcing_deps(scope + value_name)
          if symbol&.kind == :enum_value
            candidate = schema_of(symbol)
            if candidate.enum.full_name != enum.full_name
              value_error(option, "Enum type \"#{enum.full_name}\" has no value named \"#{value_name}\" for option " \
                "\"#{field.full_name}\". This appears to be a value from a sibling type.")
              return FAILED
            end
            found = candidate
          end
        end
        unless found
          value_error(option, "Enum type \"#{enum.full_name}\" has no value named \"#{value_name}\" for option " \
            "\"#{field.full_name}\".")
          return FAILED
        end
        enum.values_by_number.fetch(found.number).name.to_sym
      end

      public

      # Folds entries into a hash the way parsing their serialized form would:
      # repeated fields append, message fields merge, scalars take the last value
      def fold(entries, into = {})
        merged = {}.compare_by_identity
        entries.each do |field, value|
          if (field.type == :message || field.type == :group) && !field.repeated?
            (merged[field] ||= []).concat(value)
          else
            merged[field] ||= []
            merged[field] << value
          end
        end
        merged.each do |field, values|
          target = if field.extension?
            into[:__extensions] ||= {}
          else
            into
          end
          key = field.extension? ? field.full_name : field.name.to_sym
          if field.type == :message || field.type == :group
            if field.repeated?
              list = (target[key] ||= [])
              values.each { |v| list << fold(v) }
            else
              target[key] = fold(values, target[key] || {})
            end
          elsif field.repeated?
            (target[key] ||= []).concat(values)
          else
            target[key] = values.last
          end
        end
        into
      end
    end
  end
end
