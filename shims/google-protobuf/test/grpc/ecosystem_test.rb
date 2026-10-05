# frozen_string_literal: true

require "test/unit"
require "google/protobuf"

# Every _pb.rb that googleapis-common-protos-types ships, and grpc's health
# service, as protoc wrote them: they load, their messages round-trip, and
# their files give back the bytes they were built from
class EcosystemTest < Test::Unit::TestCase
  GOOGLEAPIS = Gem.loaded_specs.fetch("googleapis-common-protos-types")
  FILES = Dir.glob("**/*_pb.rb", base: File.join(GOOGLEAPIS.full_gem_path, "lib")).sort

  def self.embedded(path)
    eval(File.read(path)[/^descriptor_data = (".*")$/, 1]).b # standard:disable Security/Eval
  end

  def test_every_googleapis_file_loads
    assert_operator FILES.size, :>, 40
    FILES.each { |f| require f.delete_suffix(".rb") }
    require "grpc/health/v1/health_pb"
    assert_kind_of Class, Grpc::Health::V1::HealthCheckResponse
  end

  FILES.each do |relative|
    define_method("test_#{relative.delete_suffix("_pb.rb").tr("/", "_")}") do
      require relative.delete_suffix(".rb")
      bytes = self.class.embedded(File.join(GOOGLEAPIS.full_gem_path, "lib", relative))
      name = Google::Protobuf::FileDescriptorProto.decode(bytes).name
      file = Google::Protobuf::DescriptorPool.generated_pool.lookup(name)
      assert_instance_of Google::Protobuf::FileDescriptor, file
      assert_equal bytes, Google::Protobuf::FileDescriptorProto.encode(file.to_proto), "#{name} to_proto"
      Google::Protobuf::FileDescriptorProto.decode(bytes).message_type.each do |m|
        package = Google::Protobuf::FileDescriptorProto.decode(bytes).package
        klass = Google::Protobuf::DescriptorPool.generated_pool.lookup("#{package}.#{m.name}").msgclass
        message = klass.new
        assert_equal message, klass.decode(klass.encode(message))
        assert_equal message, klass.decode_json(klass.encode_json(message))
      end
    end
  end
end
