# frozen_string_literal: true

require "test_helper"
require "json"

# Custom option values, which the JSON goldens cannot carry. With the oracle,
# every options message of every corpus file is compared with the .binpb
# golden: the golden's options bytes and ours (what `to_proto` writes, custom
# options as extension bytes) are both decoded by google-protobuf against a
# pool built from the golden itself, so it knows the extensions, and printed
# as JSON. Without the oracle, targeted assertions on
# unittest_custom_options.proto still run.
class CompilerCustomOptionsTest < Minitest::Test
  OPTIONS = {
    message_type: "MessageOptions", nested_type: "MessageOptions", field: "FieldOptions",
    extension: "FieldOptions", oneof_decl: "OneofOptions", extension_range: "ExtensionRangeOptions",
    enum_type: "EnumOptions", value: "EnumValueOptions", service: "ServiceOptions", method: "MethodOptions"
  }.freeze

  CompilerSupport.goldens.each do |rel|
    define_method(:"test_options_of_#{rel.tr("/.", "__")}") do
      skip "needs PROTOSTAR_ORACLE=1 and the oracle bundle" unless Oracle.available?
      compiler = CompilerSupport.compiler
      files = compiler.compile([rel])
      set = Google::Protobuf::FileDescriptorSet.decode(File.binread(Corpus.golden(rel, :binpb)))
      golden_pool = Google::Protobuf::DescriptorPool.new
      set.file.each { |f| golden_pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(f)) }
      compared = 0
      files.zip(set.file) do |ours, theirs|
        each_options(ours.to_proto, theirs, "FileOptions") do |type, our_options, their_options, path|
          klass = golden_pool.lookup("google.protobuf.#{type}")&.msgclass
          next unless klass # the file sees no descriptor.proto, so no custom options
          expected = JSON.parse(klass.encode_json(klass.decode(Google::Protobuf.const_get(type).encode(their_options))))
          actual = JSON.parse(klass.encode_json(klass.decode(our_options.encode)))
          assert_equal expected, actual, "#{ours.name} #{path.join(".")}"
          compared += 1
        end
      end
      assert_operator compared, :>=, 0
    end
  end

  def test_unittest_custom_options_values
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    assert_equal 9876543210, file.options.extension("proto2_unittest.file_opt1")
    message = file.find_message("proto2_unittest.TestMessageWithCustomOptions")
    assert_equal(-56, message.options.extension("proto2_unittest.message_opt1"))
    assert_equal 8765432109, message.field("field1").options.extension("proto2_unittest.field_opt1")
    enum = file.find_enum("proto2_unittest.TestMessageWithCustomOptions.AnEnum")
    assert_equal(-789, enum.options.extension("proto2_unittest.enum_opt1"))
    assert_equal 123, enum.value("ANENUM_VAL2").options.extension("proto2_unittest.enum_value_opt1")
    method = file.find_service("proto2_unittest.TestServiceWithCustomOptions").rpc("Foo")
    assert_equal :METHODOPT1_VAL2, method.options.extension("proto2_unittest.method_opt1")
  end

  def test_complex_options_merge_like_protoc
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    options = file.find_message("proto2_unittest.VariousComplexOptions").options
    opt1 = options.extension("proto2_unittest.complex_opt1")
    assert_equal 42, opt1[:foo]
    assert_equal [99, 88], opt1[:foo4]
    assert_equal 324, opt1.extension("proto2_unittest.mooo")
    assert_equal({moo: 876}, opt1.extension("proto2_unittest.corge").to_h)
    opt2 = options.extension("proto2_unittest.complex_opt2")
    assert_equal [{waldo: 101}, {waldo: 212}], opt2[:barney].map(&:to_h)
    assert_equal({xyzzy: 24}, options.extension("proto2_unittest.complexopt6").to_h)
  end

  def test_aggregate_values
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    fileopt = file.options.extension("proto2_unittest.fileopt")
    assert_equal 100, fileopt[:i]
    assert_equal "FileAnnotation", fileopt[:s]
    assert_equal({s: "NestedFileAnnotation"}, fileopt[:sub].to_h)
    assert_equal({"(proto2_unittest.fileopt)": {s: "FileExtensionAnnotation"}}, fileopt[:file].to_h)
    any = fileopt[:any]
    assert_equal "type.googleapis.com/proto2_unittest.AggregateMessageSetElement", any[:type_url]
    assert_equal "\n\x19EmbeddedMessageSetElement".b, any[:value]
  end

  private

  # Walks our FileDescriptorProto and the golden's side by side
  def each_options(ours, golden, type, path = [], &block)
    yield type, ours.options, golden.options, path if ours.has_options?
    OPTIONS.each do |key, child_type|
      ours[key.to_s].each_with_index do |child, i|
        each_options(child, golden[key.to_s][i], child_type, path + [key, i], &block)
      end
    end
  end
end
