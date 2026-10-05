# frozen_string_literal: true

require "test_helper"

# protoc's own Ruby and RBS output for the compiler/ruby/*.proto files of the
# corpus, matched byte for byte
class ProtocRubyTest < Minitest::Test
  Emitters = Protostar::Compiler::Emitters
  DIR = File.join(Corpus::PROTOBUF, "src/google/protobuf/compiler/ruby")
  PROTOS = %w[
    ruby_generated_code.proto ruby_generated_code_proto2.proto ruby_generated_pkg_explicit.proto
    ruby_generated_pkg_explicit_legacy.proto ruby_generated_pkg_implicit.proto
  ].freeze

  def compile(name)
    Protostar::Compiler.new(include_paths: [DIR]).compile([name], source_info: true).last
  end

  PROTOS.each do |name|
    define_method(:"test_google_ruby_#{name.delete_suffix(".proto")}") do
      golden = File.read(File.join(DIR, name.sub(".proto", "_pb.rb")))
      assert_equal golden, Emitters::GoogleRuby.new.file(compile(name))
    end

    define_method(:"test_rbs_#{name.delete_suffix(".proto")}") do
      golden = File.read(File.join(DIR, name.sub(".proto", "_pb.rbs")))
      assert_equal golden, Emitters::Rbs.new.file(compile(name))
    end
  end

  def test_output_names
    file = compile("ruby_generated_pkg_implicit.proto")
    assert_equal ["ruby_generated_pkg_implicit_pb.rb"], Emitters::GoogleRuby.new.emit([file]).keys
    assert_equal ["ruby_generated_pkg_implicit_pb.rbs"], Emitters::Rbs.new.emit([file]).keys
  end

  def test_ruby_escape
    assert_equal "\\x05\\x41.\\n\\'\\\"\\\\", Emitters::GoogleRuby.ruby_escape("\x05A.\n'\"\\".b)
    assert_equal "\\\#{x}\\\#$y\\\#@z#a", Emitters::GoogleRuby.ruby_escape("\#{x}\#$y\#@z#a".b)
    assert_equal "\\xff\\xfe", Emitters::GoogleRuby.ruby_escape("\xFF\xFE".b)
  end

  def test_banned_ruby_package
    proto = "syntax = \"proto3\"; package x; option ruby_package = \"A;B\";"
    file = Protostar::Compiler.new.compile(["x.proto"], sources: {"x.proto" => proto}).last
    [Emitters::GoogleRuby, Emitters::Rbs, Emitters::Ruby].each do |emitter|
      error = assert_raises(Emitters::Error) { emitter.new.file(file) }
      assert_equal "Invalid character in ruby_package option: character ';' is not allowed because it could " \
        "enable code injection.", error.message
    end
  end
end
