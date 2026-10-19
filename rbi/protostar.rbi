# typed: strict

# The public API of protostar for Sorbet, the same as sig/protostar.rbs
# describes for RBS (test/rbi/runtime_rbi_test.rb keeps the two in step).
# Message classes compiled with `protostar compile --ruby_out=...` get their
# own `_pb.rbi`; the well-known types' are under rbi/protostar/google/protobuf/.
module Protostar
  VERSION = T.let(T.unsafe(nil), String)

  class Error < ::StandardError; end

  class DecodeError < Error
    sig { returns(T.nilable(Integer)) }
    def offset; end

    sig { params(message: String, offset: T.nilable(Integer)).void }
    def initialize(message, offset: T.unsafe(nil)); end
  end

  class EncodeError < Error; end

  class TypeError < ::TypeError; end

  Timestamp = Protostar::Google::Protobuf::Timestamp
  Duration = Protostar::Google::Protobuf::Duration
  Any = Protostar::Google::Protobuf::Any
  Struct = Protostar::Google::Protobuf::Struct
  Value = Protostar::Google::Protobuf::Value
  ListValue = Protostar::Google::Protobuf::ListValue
  Empty = Protostar::Google::Protobuf::Empty
  FieldMask = Protostar::Google::Protobuf::FieldMask
  DoubleValue = Protostar::Google::Protobuf::DoubleValue
  FloatValue = Protostar::Google::Protobuf::FloatValue
  Int64Value = Protostar::Google::Protobuf::Int64Value
  UInt64Value = Protostar::Google::Protobuf::UInt64Value
  Int32Value = Protostar::Google::Protobuf::Int32Value
  UInt32Value = Protostar::Google::Protobuf::UInt32Value
  BoolValue = Protostar::Google::Protobuf::BoolValue
  StringValue = Protostar::Google::Protobuf::StringValue
  BytesValue = Protostar::Google::Protobuf::BytesValue

  # A field read from the wire that the message's schema does not know
  class UnknownField
    sig { returns(Integer) }
    def number; end

    sig { returns(Integer) }
    def wire_type; end

    sig { returns(String) }
    def bytes; end

    sig { params(number: Integer, wire_type: Integer, bytes: String).void }
    def initialize(number, wire_type, bytes); end

    sig { returns(T.any(Integer, String)) }
    def value; end

    sig { returns(String) }
    def to_wire; end
  end

  # The descriptors: what a .proto file declares, frozen once built
  module Schema
    class Error < Protostar::Error; end

    class Descriptor
      sig { returns(String) }
      def name; end

      sig { returns(String) }
      def full_name; end

      sig { returns(Integer) }
      def index; end

      sig { returns(T.untyped) }
      def options; end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def to_h; end
    end

    class File < Descriptor
      sig { returns(String) }
      def package; end

      sig { returns(Symbol) }
      def syntax; end

      sig { returns(T::Array[String]) }
      def dependencies; end

      sig { returns(T::Array[Message]) }
      def messages; end

      sig { returns(T::Array[Enum]) }
      def enums; end

      sig { returns(T::Array[Service]) }
      def services; end

      sig { returns(T::Array[Message]) }
      def all_messages; end

      sig { returns(T::Array[Enum]) }
      def all_enums; end

      sig { params(full_name: String).returns(T.nilable(Message)) }
      def find_message(full_name); end

      sig { params(full_name: String).returns(T.nilable(Enum)) }
      def find_enum(full_name); end

      sig { params(source_info: T::Boolean, default_json_names: T::Boolean).returns(String) }
      def serialize(source_info: T.unsafe(nil), default_json_names: T.unsafe(nil)); end
    end

    class Message < Descriptor
      sig { returns(File) }
      def file; end

      sig { returns(T.nilable(Message)) }
      def containing_message; end

      sig { returns(T::Array[Field]) }
      def fields; end

      sig { returns(T::Array[Oneof]) }
      def oneofs; end

      sig { returns(T::Array[Oneof]) }
      def real_oneofs; end

      sig { returns(T::Array[Message]) }
      def nested_messages; end

      sig { returns(T::Array[Enum]) }
      def nested_enums; end

      sig { params(key: T.any(Integer, String, Symbol)).returns(T.nilable(Field)) }
      def field(key); end

      sig { returns(T::Boolean) }
      def map_entry?; end
    end

    class Field < Descriptor
      sig { returns(File) }
      def file; end

      sig { returns(T.nilable(Message)) }
      def containing_message; end

      sig { returns(Integer) }
      def number; end

      sig { returns(Symbol) }
      def label; end

      sig { returns(Symbol) }
      def type; end

      sig { returns(T.nilable(Message)) }
      def message_type; end

      sig { returns(T.nilable(Enum)) }
      def enum_type; end

      sig { returns(String) }
      def json_name; end

      sig { returns(T.nilable(Oneof)) }
      def oneof; end

      sig { returns(T.untyped) }
      def default; end

      sig { returns(T::Boolean) }
      def repeated?; end

      sig { returns(T::Boolean) }
      def map?; end

      sig { returns(T::Boolean) }
      def presence?; end
    end

    class Oneof < Descriptor
      sig { returns(Message) }
      def containing_message; end

      sig { returns(T::Array[Field]) }
      def fields; end

      sig { returns(T::Boolean) }
      def synthetic?; end
    end

    class Enum < Descriptor
      sig { returns(File) }
      def file; end

      sig { returns(T.nilable(Message)) }
      def containing_message; end

      sig { returns(T::Array[EnumValue]) }
      def values; end

      sig { params(key: T.any(Integer, String, Symbol)).returns(T.nilable(EnumValue)) }
      def value(key); end

      sig { returns(T::Boolean) }
      def closed?; end

      sig { returns(T::Boolean) }
      def open?; end
    end

    class EnumValue < Descriptor
      sig { returns(Integer) }
      def number; end

      sig { returns(Enum) }
      def enum; end
    end

    class Service < Descriptor
      sig { returns(File) }
      def file; end
    end

    class Pool
      sig { void }
      def initialize; end

      sig { params(file: File, warn: T::Boolean).returns(File) }
      def add(file, warn: T.unsafe(nil)); end

      sig { params(name: String).returns(T.nilable(File)) }
      def file(name); end

      sig { returns(T::Array[File]) }
      def files; end

      sig { params(full_name: String).returns(T.nilable(Message)) }
      def find_message(full_name); end

      sig { params(full_name: String).returns(T.nilable(Enum)) }
      def find_enum(full_name); end
    end
  end

  # Extended by every enum Module
  module Enum
    sig { returns(Schema::Enum) }
    def descriptor; end

    sig { params(number: Integer).returns(T.nilable(Symbol)) }
    def lookup(number); end

    sig { params(name: T.any(Symbol, String)).returns(T.nilable(Integer)) }
    def resolve(name); end
  end

  # The base class of every message class
  class Message
    sig { returns(Schema::Message) }
    def self.descriptor; end

    sig { params(bytes: T.any(String, IO::Buffer), recursion_limit: Integer, frozen: T::Boolean).returns(T.attached_class) }
    def self.decode(bytes, recursion_limit: T.unsafe(nil), frozen: T.unsafe(nil)); end

    sig do
      params(source: T.any(String, IO::Buffer, IO), recursion_limit: Integer, frozen: T::Boolean)
        .returns(T.nilable(T.attached_class))
    end
    def self.decode_delimited(source, recursion_limit: T.unsafe(nil), frozen: T.unsafe(nil)); end

    sig { params(message: Message).returns(String) }
    def self.encode(message); end

    sig do
      params(json: String, ignore_unknown_fields: T::Boolean, registry: T.nilable(Types::Registry))
        .returns(T.attached_class)
    end
    def self.decode_json(json, ignore_unknown_fields: T.unsafe(nil), registry: T.unsafe(nil)); end

    sig { params(message: Message, options: T.untyped).returns(String) }
    def self.encode_json(message, **options); end

    sig { params(a: Message, b: Message).returns(T.attached_class) }
    def self.merge(a, b); end

    sig do
      params(bytes: T.any(String, IO::Buffer), offset: Integer, length: T.nilable(Integer), recursion_limit: Integer)
        .returns(View)
    end
    def self.view(bytes, offset: T.unsafe(nil), length: T.unsafe(nil), recursion_limit: T.unsafe(nil)); end

    sig { returns(T.class_of(View)) }
    def self.view_class; end

    sig do
      params(
        fields: T.nilable(T::Hash[T.any(Symbol, String), T.untyped]),
        more: T.untyped,
        block: T.nilable(T.proc.params(pb: Builder).void)
      ).returns(T.attached_class)
    end
    def self.build(fields = T.unsafe(nil), **more, &block); end

    sig { returns(Reflection) }
    def self.reflection; end

    sig { params(hash: T.nilable(T::Hash[T.any(Symbol, String), T.untyped]), fields: T.untyped).void }
    def initialize(hash = T.unsafe(nil), **fields); end

    sig { params(name: T.any(String, Symbol)).returns(T.untyped) }
    def [](name); end

    sig { params(name: T.any(String, Symbol), value: T.untyped).returns(T.untyped) }
    def []=(name, value); end

    sig { returns(T::Array[UnknownField]) }
    def unknown_fields; end

    sig { returns(String) }
    def encode; end

    sig { type_parameters(:IO).params(io: T.type_parameter(:IO)).returns(T.type_parameter(:IO)) }
    def encode_to(io); end

    sig do
      type_parameters(:IO)
        .params(io: T.nilable(T.type_parameter(:IO)))
        .returns(T.any(String, T.type_parameter(:IO)))
    end
    def encode_delimited(io = T.unsafe(nil)); end

    sig { params(state: T.untyped, options: T.untyped).returns(String) }
    def to_json(state = T.unsafe(nil), **options); end

    sig { params(options: T.untyped).returns(String) }
    def to_text(**options); end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h; end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other); end

    sig { returns(Integer) }
    def hash; end

    sig { params(freeze: T.nilable(T::Boolean)).returns(T.self_type) }
    def clone(freeze: T.unsafe(nil)); end

    sig { returns(T.self_type) }
    def freeze; end

    sig { params(other: Message).returns(T.self_type) }
    def merge!(other); end

    sig { returns(T.self_type) }
    def clear!; end

    sig { returns(T::Boolean) }
    def initialized?; end

    sig { returns(String) }
    def inspect; end

    sig { params(q: T.untyped).void }
    def pretty_print(q); end

    # A message class's fields by descriptor, name or number (Klass.reflection)
    class Reflection
      sig { returns(T.untyped) }
      def klass; end

      sig { returns(Schema::Message) }
      def descriptor; end

      sig { returns(T::Array[T.untyped]) }
      def fields; end

      sig { returns(T::Array[T.untyped]) }
      def oneofs; end

      sig { params(key: T.untyped).returns(T.untyped) }
      def field(key); end

      sig { params(message: Message, key: T.untyped).returns(T.untyped) }
      def get(message, key); end

      sig { params(message: Message, key: T.untyped, value: T.untyped).returns(Message) }
      def set(message, key, value); end

      sig { params(message: Message, key: T.untyped).returns(T::Boolean) }
      def set?(message, key); end

      sig { params(message: Message, key: T.untyped).returns(Message) }
      def clear(message, key); end

      sig { params(message: Message, oneof: T.untyped).returns(T.untyped) }
      def which(message, oneof); end

      sig { params(key: T.untyped).returns(T.untyped) }
      def message_class(key); end

      sig { params(key: T.untyped).returns(T.untyped) }
      def enum_module(key); end

      sig do
        params(message: Message, block: T.nilable(T.proc.params(field: T.untyped, value: T.untyped).void))
          .returns(T.untyped)
      end
      def each(message, &block); end

      sig { returns(String) }
      def inspect; end
    end
  end

  # A read-only message over encoded bytes; fields are decoded when read
  class View
    sig { returns(T.class_of(Message)) }
    def self.message_class; end

    sig { returns(Schema::Message) }
    def self.descriptor; end

    sig { returns(Schema::Message) }
    def descriptor; end

    sig { params(name: T.any(String, Symbol)).returns(T.untyped) }
    def [](name); end

    sig { returns(T::Array[UnknownField]) }
    def unknown_fields; end

    sig { returns(String) }
    def encode; end

    sig { returns(String) }
    def to_proto; end

    sig { params(frozen: T::Boolean).returns(Message) }
    def to_message(frozen: T.unsafe(nil)); end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h; end

    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other); end

    sig { returns(Integer) }
    def hash; end

    sig { returns(T.self_type) }
    def freeze_index; end

    sig { returns(String) }
    def inspect; end

    sig { params(q: T.untyped).void }
    def pretty_print(q); end
  end

  module Types
    class Registry
      sig { params(open_enums: T::Boolean, base: T.class_of(Protostar::Message)).void }
      def initialize(open_enums: T.unsafe(nil), base: T.unsafe(nil)); end

      sig { params(full_name: String).returns(T.nilable(T.any(T.class_of(Message), T::Module[T.anything]))) }
      def find(full_name); end

      sig { params(file_name: String).returns(T.nilable(T::Hash[String, T.any(T.class_of(Message), T::Module[T.anything])])) }
      def file(file_name); end

      sig { params(file: T.untyped, name: T.nilable(T::Module[T.anything])).returns(T::Hash[String, T.any(T.class_of(Message), T::Module[T.anything])]) }
      def define(file, name: T.unsafe(nil)); end
    end

    sig { returns(Registry) }
    def self.registry; end

    sig do
      params(file: T.untyped, name: T.nilable(T::Module[T.anything]), registry: Registry)
        .returns(T::Hash[String, T.any(T.class_of(Message), T::Module[T.anything])])
    end
    def self.define(file, name: T.unsafe(nil), registry: T.unsafe(nil)); end

    sig { params(full_name: String, registry: Registry).returns(T.nilable(T.any(T.class_of(Message), T::Module[T.anything]))) }
    def self.find(full_name, registry: T.unsafe(nil)); end
  end

  module JSON
    class Error < Protostar::Error; end

    class ParseError < Error
      sig { returns(String) }
      def path; end

      sig { params(message: String, path: String).void }
      def initialize(message, path = T.unsafe(nil)); end
    end

    class EncodeError < Error
      sig { returns(String) }
      def path; end

      sig { params(message: String, path: String).void }
      def initialize(message, path = T.unsafe(nil)); end
    end

    sig do
      params(
        message: Message,
        preserve_proto_field_names: T::Boolean,
        preserve_proto_fieldnames: T::Boolean,
        emit_defaults: T::Boolean,
        format_enums_as_integers: T::Boolean,
        registry: T.nilable(Types::Registry)
      ).returns(String)
    end
    def self.encode(message, preserve_proto_field_names: T.unsafe(nil), preserve_proto_fieldnames: T.unsafe(nil), emit_defaults: T.unsafe(nil),
      format_enums_as_integers: T.unsafe(nil), registry: T.unsafe(nil)); end

    sig do
      type_parameters(:M)
        .params(
          klass: T::Class[T.type_parameter(:M)],
          json: String,
          ignore_unknown_fields: T::Boolean,
          registry: T.nilable(Types::Registry)
        ).returns(T.type_parameter(:M))
    end
    def self.decode(klass, json, ignore_unknown_fields: T.unsafe(nil), registry: T.unsafe(nil)); end
  end

  module Text
    class Error < Protostar::Error; end

    class ParseError < Error
      sig { returns(Integer) }
      def line; end

      sig { returns(Integer) }
      def column; end

      sig { params(message: String, line: Integer, column: Integer).void }
      def initialize(message, line, column); end
    end

    sig do
      params(
        message: T.any(Message, View),
        single_line: T::Boolean,
        expand_any: T::Boolean,
        as_utf8: T::Boolean,
        unknown_fields: T::Boolean,
        registry: T.nilable(Types::Registry),
        pool: T.untyped
      ).returns(String)
    end
    def self.print(message, single_line: T.unsafe(nil), expand_any: T.unsafe(nil), as_utf8: T.unsafe(nil), unknown_fields: T.unsafe(nil), registry: T.unsafe(nil),
      pool: T.unsafe(nil)); end

    sig do
      type_parameters(:M)
        .params(
          klass: T::Class[T.type_parameter(:M)],
          text: String,
          allow_unknown_fields: T::Boolean,
          allow_partial: T::Boolean,
          registry: T.nilable(Types::Registry),
          pool: T.untyped
        ).returns(T.type_parameter(:M))
    end
    def self.parse(klass, text, allow_unknown_fields: T.unsafe(nil), allow_partial: T.unsafe(nil), registry: T.unsafe(nil), pool: T.unsafe(nil)); end
  end

  # Writes a message's encoding as fields are given, without building the
  # message. Fields are set by calling methods named after them, which Sorbet
  # cannot see; `set!` is the typed way to set one.
  class Builder
    class Error < Protostar::Error
      sig { returns(T.nilable(String)) }
      def path; end

      sig { params(message: String, path: T.nilable(String)).void }
      def initialize(message, path: T.unsafe(nil)); end
    end

    sig do
      params(
        klass: T.untyped,
        cache_store: T.untyped,
        overwrites: T::Boolean,
        repeated: Symbol,
        buffer: Integer,
        chunk_nested_at: T.nilable(Integer),
        block: T.proc.params(pb: Builder).void
      ).returns(String)
    end
    def self.build(klass, cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil), chunk_nested_at: T.unsafe(nil), &block); end

    sig do
      params(
        klass: T.untyped,
        cache_store: T.untyped,
        overwrites: T::Boolean,
        repeated: Symbol,
        buffer: Integer,
        chunk_nested_at: T.nilable(Integer),
        block: T.proc.params(pb: Builder).void
      ).returns(Message)
    end
    def self.message(klass, cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil), chunk_nested_at: T.unsafe(nil),
      &block); end

    sig do
      type_parameters(:Sink)
        .params(
          io: T.type_parameter(:Sink),
          klass: T.untyped,
          cache_store: T.untyped,
          overwrites: T::Boolean,
          repeated: Symbol,
          buffer: Integer,
          chunk_nested_at: T.nilable(Integer),
          block: T.proc.params(pb: Builder).void
        ).returns(T.type_parameter(:Sink))
    end
    def self.write(io, klass, cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil), chunk_nested_at: T.unsafe(nil),
      &block); end

    sig do
      type_parameters(:E)
        .params(
          io: T.untyped,
          klass: T.untyped,
          collection: T::Enumerable[T.type_parameter(:E)],
          cache_store: T.untyped,
          overwrites: T::Boolean,
          repeated: Symbol,
          buffer: Integer,
          chunk_nested_at: T.nilable(Integer),
          block: T.proc.params(pb: Builder, element: T.type_parameter(:E)).void
        ).returns(T.untyped)
    end
    def self.each(io, klass, collection, cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil),
      chunk_nested_at: T.unsafe(nil), &block); end

    sig do
      params(
        klass: T.untyped,
        cache_store: T.untyped,
        overwrites: T::Boolean,
        repeated: Symbol,
        buffer: Integer,
        chunk_nested_at: T.nilable(Integer),
        block: T.proc.params(pb: Builder).void
      ).returns(T::Enumerator[String])
    end
    def self.each_chunk(klass, cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil), chunk_nested_at: T.unsafe(nil),
      &block); end

    sig do
      params(
        klass: T.untyped,
        target: T.untyped,
        cache_store: T.untyped,
        overwrites: T::Boolean,
        repeated: Symbol,
        buffer: Integer,
        chunk_nested_at: T.nilable(Integer)
      ).returns(Builder)
    end
    def self.new(klass, target = T.unsafe(nil), cache_store: T.unsafe(nil), overwrites: T.unsafe(nil), repeated: T.unsafe(nil), buffer: T.unsafe(nil),
      chunk_nested_at: T.unsafe(nil)); end

    sig { params(klass: T.untyped).returns(T.class_of(Builder)) }
    def self.for(klass); end

    sig { params(klass: T.untyped).returns(T.class_of(Message)) }
    def self.resolve(klass); end

    sig { returns(T.untyped) }
    def target!; end

    sig { returns(T.class_of(Message)) }
    def message_class; end

    sig do
      params(name: T.any(String, Symbol), value_and_attributes: T.untyped, block: T.nilable(T.proc.params(element: T.untyped).void))
        .returns(T.self_type)
    end
    def set!(name, *value_and_attributes, &block); end

    sig { params(object: T.untyped, names: T.any(String, Symbol)).returns(T.self_type) }
    def extract!(object, *names); end

    sig { params(hash: T::Hash[T.any(String, Symbol), T.untyped]).returns(T.self_type) }
    def merge!(hash); end

    sig { params(name: T.any(String, Symbol), bytes: T.any(String, T::Array[String])).returns(T.self_type) }
    def encoded!(name, bytes); end

    sig { params(key: T.untyped, options: T.untyped, block: T.proc.params(pb: Builder).void).returns(T.self_type) }
    def cache!(key, **options, &block); end

    sig do
      params(condition: T.untyped, key: T.untyped, options: T.untyped, block: T.proc.params(pb: Builder).void)
        .returns(T.self_type)
    end
    def cache_if!(condition, key, **options, &block); end
  end

  # Helpers mixed into the well-known types, as google-protobuf names them
  module WellKnown
    class UnexpectedStructType < Protostar::Error; end

    module Any
      DEFAULT_PREFIX = T.let(T.unsafe(nil), String)

      module ClassMethods
        sig { params(message: Message, type_url_prefix: String).returns(Protostar::Google::Protobuf::Any) }
        def pack(message, type_url_prefix = T.unsafe(nil)); end
      end

      sig { params(message: Message, type_url_prefix: String).returns(T.self_type) }
      def pack(message, type_url_prefix = T.unsafe(nil)); end

      sig { params(klass: T.class_of(Message)).returns(T.nilable(Message)) }
      def unpack(klass); end

      sig { returns(String) }
      def type_name; end

      sig { params(klass: T.class_of(Message)).returns(T::Boolean) }
      def is(klass); end
    end

    module Timestamp
      sig { params(value: T.untyped).returns(T.nilable([Integer, Integer])) }
      def self.parts(value); end

      module ClassMethods
        sig { params(time: ::Time).returns(Protostar::Google::Protobuf::Timestamp) }
        def from_time(time); end
      end

      sig { params(time: ::Time).returns(T.self_type) }
      def from_time(time); end

      sig { returns(::Time) }
      def to_time; end

      sig { returns(Integer) }
      def to_i; end

      sig { returns(Rational) }
      def to_f; end
    end

    module Duration
      MAX_SECONDS = T.let(T.unsafe(nil), Integer)
      NANOS = T.let(T.unsafe(nil), Integer)

      sig { params(value: T.untyped).returns(T.nilable([Integer, Integer])) }
      def self.parts(value); end

      module ClassMethods; end

      sig { returns(Float) }
      def to_f; end
    end

    module Struct
      module ClassMethods
        sig { params(hash: T::Hash[String, T.untyped]).returns(Protostar::Google::Protobuf::Struct) }
        def from_hash(hash); end
      end

      sig { params(key: String).returns(T.untyped) }
      def [](key); end

      sig { params(key: String, value: T.untyped).returns(T.untyped) }
      def []=(key, value); end

      sig { returns(T::Hash[String, T.untyped]) }
      def to_h; end

      sig { params(key: String).returns(T::Boolean) }
      def has_key?(key); end
    end

    module Value
      module ClassMethods
        sig { params(value: T.untyped).returns(Protostar::Google::Protobuf::Value) }
        def from_ruby(value); end
      end

      sig { params(recursive: T::Boolean).returns(T.untyped) }
      def to_ruby(recursive = T.unsafe(nil)); end

      sig { params(value: T.untyped).returns(T.self_type) }
      def from_ruby(value); end
    end

    module ListValue
      include ::Enumerable
      extend T::Generic

      Elem = type_member { {fixed: T.untyped} }

      module ClassMethods
        sig { params(array: T::Array[T.untyped]).returns(Protostar::Google::Protobuf::ListValue) }
        def from_a(array); end
      end

      sig { returns(Integer) }
      def length; end

      sig { params(index: Integer).returns(T.untyped) }
      def [](index); end

      sig { params(index: Integer, value: T.untyped).returns(T.untyped) }
      def []=(index, value); end

      sig { params(value: T.untyped).returns(T.self_type) }
      def <<(value); end

      sig { params(block: T.nilable(T.proc.params(value: T.untyped).void)).returns(T.untyped) }
      def each(&block); end

      sig { returns(T::Array[T.untyped]) }
      def to_a; end
    end
  end
end

# Ruby 3.1 and later; not in every Sorbet release's standard library RBI
class IO
  class Buffer; end
end
