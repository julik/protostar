# frozen_string_literal: true

require "test_helper"

# The translation layer: Schema::File#to_proto, Schema::File.from_proto, the
# option value codec and the Pool conveniences
class ProtoTest < Minitest::Test
  PB = Protostar::Schema::Proto.types
  S = Protostar::Schema

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
    assert_equal message.options, files.last.options.to_proto
    assert_kind_of PB::FileOptions, files.last.options.to_proto
  end

  def test_from_proto_decodes_extensions_from_the_pool
    files, = custom_options
    pool = S::Pool.new
    files[0..-2].each { |f| pool.add(S::File.from_proto(f.to_proto, pool: pool)) }
    rebuilt = S::File.from_proto(files.last.to_proto, pool: pool)
    assert_equal files.last.serialize, rebuilt.serialize
    refute pool.include?(rebuilt.name)
    assert_equal 9876543210, rebuilt.options.extension("proto2_unittest.file_opt1")
    assert_same rebuilt.find_extension("proto2_unittest.file_opt1"),
      rebuilt.options.extensions.keys.find { |f| f.full_name == "proto2_unittest.file_opt1" }
  end

  def test_from_proto_takes_bytes
    file = CompilerSupport.compiler.compile(["google/protobuf/timestamp.proto"]).last
    rebuilt = S::File.from_proto(file.serialize, pool: S::Pool.new)
    assert_equal file.to_h, rebuilt.to_h
    assert_equal file.serialize, rebuilt.serialize
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
    pool = S::Pool.new
    pool.add_serialized_file(files.find { |f| f.name == "google/protobuf/descriptor.proto" }.serialize)
    SchemaFixtures.add(pool, "opts.proto", dependencies: ["google/protobuf/descriptor.proto"])
    rebuilt = S::File.from_proto(bytes, pool: pool)
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
    aggregate = file.options.extension("proto2_unittest.fileopt")
    type = file.find_message("proto2_unittest.Aggregate")
    bytes = aggregate.encode(type)
    lookup = ->(extendee, number) { file.all_extensions.find { |e| e.extendee.full_name == extendee && e.number == number } }
    assert_equal aggregate, S::MessageValue.decode(type, bytes, lookup)
    set_type = file.find_message("proto2_unittest.AggregateMessageSet")
    item = aggregate[:mset].encode(set_type)
    assert_equal "\v\x10\xF6\xEB\xAE\a\x1A\e\n\x19EmbeddedMessageSetElement\f".b, item
    unknown = S::MessageValue.decode(set_type, item)
    assert_empty unknown.extensions
    assert_equal item, unknown.unknown_fields
    assert_equal item, unknown.encode(set_type)
  end

  def test_json_names_can_be_left_to_their_default
    file = Protostar::Compiler.new.compile(["j.proto"], sources: {"j.proto" => <<~PROTO}).last
      syntax = "proto3";
      message M { int32 snake_case = 1; int32 custom = 2 [json_name = "other"]; }
    PROTO
    fields = file.to_proto(default_json_names: false).message_type.first.field
    refute fields[0].has_json_name?
    assert_equal "other", fields[1].json_name
    assert_equal "snakeCase", file.to_proto.message_type.first.field[0].json_name
  end
end
