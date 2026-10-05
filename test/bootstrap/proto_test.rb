# frozen_string_literal: true

require "test_helper"

# Schema::File#to_proto, Builder.from_proto and the Pool conveniences
class ProtoTest < Minitest::Test
  PB = Protostar::Schema::Proto.types
  Codec = Protostar::Schema::Proto::HashCodec

  def custom_options
    @custom_options ||= begin
      compiler = CompilerSupport.compiler
      [compiler.compile(["google/protobuf/unittest_custom_options.proto"]), compiler]
    end
  end

  def test_custom_options_travel_as_extension_bytes
    files, = custom_options
    message = files.last.to_proto
    unknown = message.options.unknown_fields
    file_opt1 = unknown.find { |u| u.number == 7736974 }
    assert file_opt1, "file_opt1 is an unknown field of the bootstrap's FileOptions"
    assert_equal 9876543210, file_opt1.value
  end

  def test_from_proto_decodes_extensions_from_the_pool
    files, compiler = custom_options
    pool = Protostar::Schema::Pool.new
    files[0..-2].each { |f| pool.add(Protostar::Schema::Builder.from_proto(f.to_proto, pool: pool)) }
    rebuilt = Protostar::Schema::Builder.from_proto(files.last.to_proto, pool: pool)
    assert_equal EmitterSupport.comparable(files.last.to_h), EmitterSupport.comparable(rebuilt.to_h)
    refute pool.include?(rebuilt.name)
    assert_equal 9876543210, rebuilt.options.extension("proto2_unittest.file_opt1")
    assert compiler
  end

  def test_from_proto_takes_bytes
    file = CompilerSupport.compiler.compile(["google/protobuf/timestamp.proto"]).last
    rebuilt = Protostar::Schema::Builder.from_proto(file.serialize, pool: Protostar::Schema::Pool.new)
    assert_equal file.to_h, rebuilt.to_h
  end

  def test_unknown_extensions_stay_unknown_and_reserialize
    source = <<~PROTO
      syntax = "proto2";
      import "google/protobuf/descriptor.proto";
      package opts;
      extend google.protobuf.MessageOptions { optional int32 level = 50001; repeated string tags = 50002; }
    PROTO
    user = <<~PROTO
      syntax = "proto2";
      import "opts.proto";
      package app;
      message M { option (opts.level) = 7; option (opts.tags) = "a"; option (opts.tags) = "b"; }
    PROTO
    compiler = Protostar::Compiler.new
    files = compiler.compile(["app.proto"], sources: {"opts.proto" => source, "app.proto" => user})
    app = files.last
    bytes = app.serialize
    pool = Protostar::Schema::Pool.new
    pool.add_serialized_file(files.find { |f| f.name == "google/protobuf/descriptor.proto" }.serialize)
    stub = Protostar::Schema::Builder.build({name: "opts.proto", dependency: ["google/protobuf/descriptor.proto"]}, pool: pool)
    pool.add(stub)
    rebuilt = Protostar::Schema::Builder.from_proto(bytes, pool: pool)
    options = rebuilt.messages.first.options
    assert_empty options.extensions
    assert_equal "\x88\xb5\x18\x07\x92\xb5\x18\x01a\x92\xb5\x18\x01b".b, options.unknown_fields
    assert_equal bytes, rebuilt.serialize
  end

  def test_pool_conveniences
    files = CompilerSupport.compiler.compile(["google/protobuf/unittest_import.proto"])
    set = Protostar::Compiler::Emitters::DescriptorSet.new.emit(files)
    pool = Protostar::Pool.new
    loaded = pool.load_descriptor_set(set)
    assert_equal files.map(&:name), loaded.map(&:name)
    assert_same loaded.first, pool.add_serialized_file(files.first.serialize)
    assert_equal loaded, Protostar.load_descriptor_set(set, pool: pool)
  end

  def test_message_set_items
    files, = custom_options
    file = files.last
    aggregate = file.options.extension("proto2_unittest.fileopt").__legacy_h
    type = file.find_message("proto2_unittest.Aggregate")
    finder = ->(name) { file.find_extension(name) }
    bytes = Codec.encode(type, aggregate, finder)
    lookup = ->(extendee, number) { file.all_extensions.find { |e| e.extendee.full_name == extendee && e.number == number } }
    assert_equal aggregate, Codec.decode(type, bytes, lookup, keep_unknown: true)
    set_type = file.find_message("proto2_unittest.AggregateMessageSet")
    item = Codec.encode(set_type, aggregate[:mset], finder)
    assert_equal "\v\x10\xF6\xEB\xAE\a\x1A\e\n\x19EmbeddedMessageSetElement\f".b, item
    unknown = Codec.decode(set_type, item, nil, keep_unknown: true)
    assert_equal [[1, 3, item.byteslice(1..)]], unknown[:__unknown_fields]
    assert_equal item, Codec.encode(set_type, unknown, finder)
  end
end
