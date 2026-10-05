# frozen_string_literal: true

require "test_helper"

# Byte equality with what grpc-tools' Ruby plugin wrote (see
# script/record_grpc_goldens.rb and test/corpus/generated/grpc/VERSION)
class GrpcEmitterTest < Minitest::Test
  Emitters = Protostar::Compiler::Emitters
  DIR = File.join(Corpus::ROOT, "generated/grpc")
  PROTOS = File.join(DIR, "protos")
  CASES = {
    "service_test.proto" => File.join(Corpus::PROTOBUF, "ruby/tests"),
    "acme/streaming.proto" => PROTOS,
    "acme/types.proto" => PROTOS,
    "acme/no_package.proto" => PROTOS
  }.freeze

  CASES.each do |name, include_dir|
    define_method(:"test_#{name.tr("/.", "__")}") do
      file = Protostar::Compiler.new(include_paths: [include_dir, PROTOS]).compile([name], source_info: true).last
      golden = File.read(File.join(DIR, "out", Emitters::Grpc.output_name(name)))
      assert_equal golden, Emitters::Grpc.new.file(file)
      assert_equal({Emitters::Grpc.output_name(name) => golden}, Emitters::Grpc.new.emit([file]))
    end
  end

  def test_every_golden_is_covered
    goldens = Dir.chdir(File.join(DIR, "out")) { Dir["**/*.rb"] }.sort
    assert_equal CASES.keys.map { |n| Emitters::Grpc.output_name(n) }.sort, goldens
  end

  def test_files_without_services_emit_nothing
    file = Protostar::Compiler.new.compile(["google/protobuf/timestamp.proto"]).last
    assert_equal "", Emitters::Grpc.new.file(file)
    assert_empty Emitters::Grpc.new.emit([file])
  end

  def test_output_name
    assert_equal "a/b_services_pb.rb", Emitters::Grpc.output_name("a/b.proto")
    assert_raises(Emitters::Error) { Emitters::Grpc.output_name("x.txt") }
  end
end
