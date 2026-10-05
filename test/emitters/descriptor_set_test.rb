# frozen_string_literal: true

require "test_helper"

# --descriptor_set_out: for every corpus file, compiled with source info and
# its imports, the bytes equal protoc's .binpb golden exactly
class DescriptorSetEmitterTest < Minitest::Test
  Emitters = Protostar::Compiler::Emitters
  FileDescriptorProto = Protostar::Schema::Proto.types::FileDescriptorProto

  CompilerSupport.goldens.each do |rel|
    define_method(:"test_#{rel.tr("/.", "__")}") do
      compiled = EmitterSupport.compiled(rel)
      files = compiled.files
      named = files.select { |f| f.name == rel }
      emitter = Emitters::DescriptorSet.new(include_imports: true, include_source_info: true,
        pool: compiled.compiler.pool)
      golden = File.binread(Corpus.golden(rel, :binpb))
      assert_equal golden, emitter.emit(named, available: files)
    end
  end

  def test_without_imports_or_source_info
    rel = "google/protobuf/unittest.proto"
    files = CompilerSupport.compiler.compile([rel], source_info: true)
    named = files.select { |f| f.name == rel }
    entries = Protostar::Schema::Proto.each_file(Emitters::DescriptorSet.new.emit(named))
    assert_equal 1, entries.size
    message = FileDescriptorProto.decode(entries.first)
    assert_equal rel, message.name
    refute message.has_source_code_info?
    golden = Protostar::Schema::Proto.each_file(File.binread(Corpus.golden(rel, :binpb))).last
    expected = FileDescriptorProto.decode(golden)
    expected.clear_source_code_info
    assert_equal expected.encode, entries.first
  end

  def test_imports_come_once_and_before_their_dependents
    names = %w[google/protobuf/unittest.proto google/protobuf/unittest_proto3.proto]
    files = CompilerSupport.compiler.compile(names)
    named = files.select { |f| names.include?(f.name) }
    bytes = Emitters::DescriptorSet.new(include_imports: true).emit(named)
    written = Protostar::Schema::Proto.each_file(bytes).map { |b| FileDescriptorProto.decode(b).name }
    assert_equal written.uniq, written
    assert_equal "google/protobuf/unittest_proto3.proto", written.last
    assert_operator written.index("google/protobuf/unittest_import.proto"), :<,
      written.index("google/protobuf/unittest.proto")
  end
end
