# frozen_string_literal: true

require "test/unit"
require "google/protobuf"
require "google/protobuf/timestamp_pb"
require "google/protobuf/descriptor_pb"
require "protostar/google/protobuf/timestamp_pb"
require "basic_test_pb"

# The shim's pools against protostar's own: separate schema pools, separate
# registries, separate classes, the same bytes
class PoolsTest < Test::Unit::TestCase
  Pool = Google::Protobuf::DescriptorPool

  def file_bytes(name, package, messages)
    Google::Protobuf::FileDescriptorProto.encode(
      Google::Protobuf::FileDescriptorProto.new(name: name, package: package, syntax: "proto3", message_type: messages)
    )
  end

  def test_native_and_google_well_known_types_are_separate_classes_with_the_same_bytes
    google = Google::Protobuf::Timestamp
    native = Protostar::Google::Protobuf::Timestamp
    refute_same google, native
    assert_instance_of Google::Protobuf::Descriptor, google.descriptor
    assert_instance_of Protostar::Schema::Message, native.descriptor
    assert_equal native.new(seconds: 5, nanos: 1).encode, google.new(seconds: 5, nanos: 1).to_proto
    assert_equal 5, google.decode(native.new(seconds: 5).encode).seconds
    refute_same Protostar.generated_pool, Pool.generated_pool.__schema_pool
    refute_same Protostar::Types.registry, Pool.generated_pool.__registry
    assert_same native, Protostar::Types.find("google.protobuf.Timestamp")
    assert_same google, Pool.generated_pool.__registry.find("google.protobuf.Timestamp")
  end

  def test_dsl_files_stay_in_protostars_pool
    Protostar::DSL.file("shimtest/native.proto", package: "shimtest.native", syntax: :proto3) do |f|
      f.message("Thing") { |m| m.field :name, 1, :string }
    end
    native = Protostar::DSL.message("shimtest.native.Thing")
    assert_equal "x", native.new(name: "x").name
    assert_nil Pool.generated_pool.lookup("shimtest.native.Thing")
    assert_nil Protostar.generated_pool.find_message("basic_test.TestMessage")
  end

  def test_one_file_in_two_pools_makes_two_class_sets
    bytes = file_bytes("twice.proto", "twice", [{name: "M", field: [{name: "a", number: 1, type: :TYPE_INT32, label: :LABEL_OPTIONAL}]}])
    first = Pool.new
    second = Pool.new
    first.add_serialized_file(bytes)
    second.add_serialized_file(bytes)
    a = first.lookup("twice.M").msgclass
    b = second.lookup("twice.M").msgclass
    refute_same a, b
    assert_equal 3, b.decode(a.encode(a.new(a: 3))).a
    refute_equal a.new(a: 1), b.new(a: 1)
  end

  def test_add_serialized_file_errors
    pool = Pool.new
    assert_raises(::TypeError) { pool.add_serialized_file(5) }
    assert_raises(ArgumentError) { pool.add_serialized_file("\xff\xff".b) }
    missing = Google::Protobuf::FileDescriptorProto.encode(Google::Protobuf::FileDescriptorProto.new(name: "x.proto", dependency: ["nope.proto"]))
    error = assert_raises(Google::Protobuf::TypeError) { pool.add_serialized_file(missing) }
    assert_equal "Unable to build file to DescriptorPool: Depends on file 'nope.proto', but it has not been loaded", error.message
    bytes = file_bytes("dup.proto", "dup", [{name: "M"}])
    pool.add_serialized_file(bytes)
    error = assert_raises(Google::Protobuf::TypeError) { pool.add_serialized_file(bytes) }
    assert_match "duplicate file name dup.proto", error.message
  end

  def test_lookup_finds_every_kind_and_returns_the_same_wrapper
    pool = Pool.generated_pool
    assert_instance_of Google::Protobuf::Descriptor, pool.lookup("basic_test.TestMessage")
    assert_instance_of Google::Protobuf::EnumDescriptor, pool.lookup("basic_test.TestEnum")
    assert_instance_of Google::Protobuf::FileDescriptor, pool.lookup("basic_test.proto")
    assert_instance_of Google::Protobuf::FieldDescriptor, pool.lookup("basic_test.test_top_level_option")
    assert_nil pool.lookup("basic_test.TestMessage.optional_int32"), "plain fields are not looked up"
    assert_nil pool.lookup("nope")
    assert_same pool.lookup("basic_test.TestMessage"), BasicTest::TestMessage.descriptor
    assert_same BasicTest::TestMessage, pool.lookup("basic_test.TestMessage").msgclass
    assert_same BasicTest::TestEnum, pool.lookup("basic_test.TestEnum").enummodule
  end

  def test_file_to_proto_gives_back_the_generated_bytes
    %w[basic_test_pb.rb ../../lib/google/protobuf/timestamp_pb.rb].each do |path|
      source = File.read(File.expand_path("../google/#{path}", __dir__))
      embedded = eval(source[/^descriptor_data = (".*")$/, 1]).b # standard:disable Security/Eval
      name = Google::Protobuf::FileDescriptorProto.decode(embedded).name
      file = Pool.generated_pool.lookup(name)
      assert_equal embedded, Google::Protobuf::FileDescriptorProto.encode(file.to_proto), name
    end
  end
end
