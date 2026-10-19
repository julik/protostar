# frozen_string_literal: true

module Protostar
  class Compiler
    module Emitters
      # What field readers return and writers take, shared by the RBS and RBI
      # emitters. The model decides the types; a dialect (RBS or Sorbet)
      # spells them.
      #
      # For protostar's classes the types are what Message::Coercion accepts
      # and what readers return. For google-protobuf's they are what the gem's
      # accessors take, as protoc's RBS has them.
      class FieldTypes
        INTEGERS = %i[fixed32 fixed64 int32 int64 sfixed32 sfixed64 sint32 sint64 uint32 uint64].freeze
        # Ruby values Message::Coercion turns into these messages, for protostar's classes
        COERCED = {
          "google.protobuf.Timestamp" => :time,
          "google.protobuf.Duration" => :numeric
        }.freeze
        # ... and what google-protobuf's accessors take for them
        GOOGLE_COERCED = {
          "google.protobuf.Timestamp" => :time,
          "google.protobuf.Duration" => :int
        }.freeze

        # RBS spelling
        module RBS
          ATOMS = {float: "::Float", integer: "::Integer", bool: "bool", string: "::String", symbol: "::Symbol",
                   time: "::Time", numeric: "::Numeric", int: "::int"}.freeze

          module_function

          def atom(name) = ATOMS.fetch(name)

          def enum_names(const) = "#{const}::names"

          def enum_strings(const) = "#{const}::strings"

          def init_map(const) = "#{const}::init_map"

          def union(types) = types.join(" | ")

          def nilable(type) = type.include?("|") ? "(#{type})?" : "#{type}?"

          def array(type) = "::Array[#{type}]"

          def hash(key, value) = "::Hash[#{key}, #{value}]"

          def generic(name, *types) = "#{name}[#{types.join(", ")}]"
        end

        # Sorbet's `sig` spelling. Everything is spelled from the root, since a
        # message may well be called `T` or `String`
        module Sorbet
          ATOMS = {float: "::Float", integer: "::Integer", bool: "::T::Boolean", string: "::String",
                   symbol: "::Symbol", time: "::Time", numeric: "::Numeric", int: "::Integer"}.freeze
          # What a Hash of field values is, wherever RBS has an init_map
          FIELDS = "::T::Hash[::T.any(::Symbol, ::String), ::T.untyped]"

          module_function

          def atom(name) = ATOMS.fetch(name)

          def enum_names(_const) = "::Symbol"

          def enum_strings(_const) = "::String"

          def init_map(_const) = FIELDS

          def union(types)
            types = types.uniq
            (types.size == 1) ? types.first : "::T.any(#{types.join(", ")})"
          end

          def nilable(type) = "::T.nilable(#{type})"

          def array(type) = "::T::Array[#{type}]"

          def hash(key, value) = "::T::Hash[#{key}, #{value}]"

          def generic(name, *types) = "#{name}[#{types.join(", ")}]"
        end

        # - `dialect`: RBS or Sorbet
        # - `google`: google-protobuf's classes rather than protostar's
        # - `constant`: the constant path of a Schema::Message or Schema::Enum
        #: (Module dialect, ?google: bool) ?{ (?) -> untyped } -> void
        def initialize(dialect, google: false, &constant)
          @d = dialect
          @google = google
          @constant = constant
        end

        # Returns what the reader returns for one value.
        #: (untyped field) -> String
        def read_one(field)
          case field.type
          when :double, :float then @d.atom(:float)
          when *INTEGERS then @d.atom(:integer)
          when :bool then @d.atom(:bool)
          when :string, :bytes then @d.atom(:string)
          when :enum then @d.union([@d.enum_names(@constant.call(field.enum_type)), @d.atom(:integer)])
          else @constant.call(field.message_type)
          end
        end

        # Returns what the writer takes for one value.
        #: (untyped field) -> String
        def write_one(field)
          return google_write_one(field) if @google
          case field.type
          when :double, :float then @d.union([@d.atom(:float), @d.atom(:integer)])
          when :enum, :message, :group then (field.type == :enum) ? read_one(field) : message_write(field, COERCED)
          else read_one(field)
          end
        end

        # Returns the reader's type.
        #: (untyped field) -> String
        def read_type(field)
          if field.map?
            k = read_one(field.map_key)
            v = read_one(field.map_value)
            @google ? @d.generic("::Google::Protobuf::Map", k, v) : @d.hash(k, v)
          elsif field.repeated?
            @google ? @d.generic("::Google::Protobuf::RepeatedField", read_one(field)) : @d.array(read_one(field))
          elsif message?(field)
            @d.nilable(read_one(field))
          else
            read_one(field)
          end
        end

        # Returns the writer's type.
        #: (untyped field) -> String
        def write_type(field)
          if @google
            return read_type(field) if field.map? || field.repeated?
            return (message?(field) || field.real_oneof) ? @d.nilable(write_one(field)) : write_one(field)
          end
          @d.nilable(container(field) { |f| write_one(f) })
        end

        # Returns what `new` takes for the field.
        #: (untyped field) -> String
        def init_type(field)
          return write_type(field) unless @google
          if message?(field) && !field.repeated?
            name = @constant.call(field.message_type)
            return @d.nilable(@d.union([name, @d.init_map(name)]))
          end
          @d.nilable(container(field) { |f| write_one(f) })
        end

        #: (untyped field) -> bool
        def message?(field)
          field.type == :message || field.type == :group
        end

        private

        def container(field)
          if field.map?
            @d.hash(yield(field.map_key), yield(field.map_value))
          elsif field.repeated?
            @d.array(yield(field))
          else
            yield(field)
          end
        end

        def message_write(field, coerced)
          name = @constant.call(field.message_type)
          extra = coerced[field.message_type.full_name]
          @d.union([name, @d.init_map(name), (@d.atom(extra) if extra)].compact)
        end

        def google_write_one(field)
          case field.type
          when :double, :float then @d.union([@d.atom(:float), @d.atom(:integer)])
          when *INTEGERS then @d.union([@d.atom(:integer), @d.atom(:float)])
          when :string then @d.union([@d.atom(:string), @d.atom(:symbol)])
          when :enum
            name = @constant.call(field.enum_type)
            @d.union([@d.enum_names(name), @d.enum_strings(name), @d.atom(:integer), @d.atom(:float)])
          when :message, :group
            name = @constant.call(field.message_type)
            extra = GOOGLE_COERCED[field.message_type.full_name]
            @d.union([name, (@d.atom(extra) if extra)].compact)
          else read_one(field)
          end
        end
      end
    end
  end
end
