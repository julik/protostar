# frozen_string_literal: true

require "test_helper"
require_relative "../../script/bootstrap"

# The committed lib/protostar/google/protobuf/*_pb.rb files
class BootstrapTest < Minitest::Test
  PB = Protostar::Schema::Proto.types
  Emitters = Protostar::Compiler::Emitters

  def test_committed_files_are_what_the_compiler_generates
    assert_empty Bootstrap.differences
  end

  def test_every_bootstrap_file_is_committed
    assert_equal Emitters::BOOTSTRAP.size, Bootstrap.generate.keys.count { |path| path.end_with?(".rb") }
    assert_equal Emitters::BOOTSTRAP.size, Bootstrap.generate.keys.count { |path| path.end_with?(".rbs") }
    Bootstrap.generate.each_key { |path| assert File.file?(path), path }
  end

  def test_descriptor_classes_live_under_protostar
    assert_same PB, Protostar::Google::Protobuf
    assert PB::FileDescriptorProto < Protostar::Message
    assert_equal "google.protobuf.FileDescriptorProto", PB::FileDescriptorProto.descriptor.full_name
    assert_equal "google.protobuf.FieldDescriptorProto.Type", PB::FieldDescriptorProto::Type.descriptor.full_name
    assert_equal 9, PB::FieldDescriptorProto::Type::TYPE_STRING
    assert_same PB::FileDescriptorProto, Protostar::Types.find("google.protobuf.FileDescriptorProto")
    if defined?(::Google::Protobuf::FileDescriptorProto)
      refute_same PB::FileDescriptorProto, ::Google::Protobuf::FileDescriptorProto
    end
  end

  def test_every_bootstrap_file_loads_and_matches_the_bundled_proto
    names = Emitters::BOOTSTRAP
    names.each { |name| require "protostar/#{Emitters::Naming.require_name(name)}" }
    compiled = Protostar::Compiler.new.compile(names)
    compiled.each do |file|
      loaded = Protostar.generated_pool.file(file.name)
      assert loaded, file.name
      assert_equal EmitterSupport.comparable(file.to_h), EmitterSupport.comparable(loaded.to_h), file.name
      assert Ractor.shareable?(loaded)
    end
    assert_equal "google.protobuf.compiler.CodeGeneratorRequest",
      Protostar::Google::Protobuf::Compiler::CodeGeneratorRequest.descriptor.full_name
    assert_equal "google.protobuf.Timestamp", Protostar::Google::Protobuf::Timestamp.descriptor.full_name
    assert_equal "google.protobuf.Value", Protostar::Google::Protobuf::Value.descriptor.full_name
    assert_equal 0, Protostar::Google::Protobuf::NullValue::NULL_VALUE
  end

  def test_requires_point_at_the_bootstrap
    source = File.read(File.expand_path("../../lib/protostar/google/protobuf/api_pb.rb", __dir__))
    assert_includes source, "require \"protostar/google/protobuf/source_context_pb\"\n"
    assert_includes source, "require \"protostar/google/protobuf/type_pb\"\n"
    assert_includes source, "module Protostar\n  module Google\n    module Protobuf\n"
  end

  def test_descriptor_messages_round_trip
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest.proto"]).last
    message = file.to_proto
    assert_instance_of PB::FileDescriptorProto, message
    assert_equal "google/protobuf/unittest.proto", message.name
    assert_equal "proto2_unittest", message.package
    assert_equal :TYPE_INT32, message.message_type.first.field.first.type
    assert_equal message, PB::FileDescriptorProto.decode(message.encode)
    assert_equal file.serialize, message.encode
  end

  def test_classes_are_shareable
    assert Ractor.shareable?(PB::FileDescriptorProto)
    assert Ractor.shareable?(PB::FieldDescriptorProto::Type)
  end
end
