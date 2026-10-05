# frozen_string_literal: true

require "test_helper"
require "json"

# Custom option values, which the JSON goldens cannot carry. With the oracle,
# every options message of every corpus file is compared with the .binpb
# golden: the golden's options bytes are decoded by google-protobuf against a
# pool built from the golden itself (so it knows the extensions) and printed
# as JSON, and our options hash is printed as the same JSON. Without the
# oracle, targeted assertions on unittest_custom_options.proto still run.
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
      json = OptionJson.new(compiler, golden_pool)
      compared = 0
      files.zip(set.file) do |ours, theirs|
        each_options(ours.to_h, theirs, "FileOptions") do |type, our_options, their_options, path|
          klass = golden_pool.lookup("google.protobuf.#{type}")&.msgclass
          next unless klass # the file sees no descriptor.proto, so no custom options
          expected = JSON.parse(klass.encode_json(klass.decode(Google::Protobuf.const_get(type).encode(their_options))))
          actual = JSON.parse(klass.encode_json(klass.decode_json(JSON.generate(json.message(our_options, type)))))
          assert_equal expected, actual, "#{ours.name} #{path.join(".")}"
          compared += 1
        end
      end
      assert_operator compared, :>=, 0
    end
  end

  def test_unittest_custom_options_values
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    assert_equal 9876543210, file.options.extensions["proto2_unittest.file_opt1"]
    message = file.find_message("proto2_unittest.TestMessageWithCustomOptions")
    assert_equal(-56, message.options.extensions["proto2_unittest.message_opt1"])
    assert_equal 8765432109, message.field("field1").options.extensions["proto2_unittest.field_opt1"]
    enum = file.find_enum("proto2_unittest.TestMessageWithCustomOptions.AnEnum")
    assert_equal(-789, enum.options.extensions["proto2_unittest.enum_opt1"])
    assert_equal 123, enum.value("ANENUM_VAL2").options.extensions["proto2_unittest.enum_value_opt1"]
    method = file.find_service("proto2_unittest.TestServiceWithCustomOptions").rpc("Foo")
    assert_equal :METHODOPT1_VAL2, method.options.extensions["proto2_unittest.method_opt1"]
  end

  def test_complex_options_merge_like_protoc
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    options = file.find_message("proto2_unittest.VariousComplexOptions").options.extensions
    opt1 = options.fetch("proto2_unittest.complex_opt1")
    assert_equal 42, opt1[:foo]
    assert_equal [99, 88], opt1[:foo4]
    assert_equal 324, opt1[:__extensions]["proto2_unittest.mooo"]
    assert_equal({moo: 876}, opt1[:__extensions]["proto2_unittest.corge"])
    opt2 = options.fetch("proto2_unittest.complex_opt2")
    assert_equal [{waldo: 101}, {waldo: 212}], opt2[:barney]
    assert_equal({xyzzy: 24}, options.fetch("proto2_unittest.complexopt6"))
  end

  def test_aggregate_values
    file = CompilerSupport.compiler.compile(["google/protobuf/unittest_custom_options.proto"]).last
    fileopt = file.options.extensions.fetch("proto2_unittest.fileopt")
    assert_equal 100, fileopt[:i]
    assert_equal "FileAnnotation", fileopt[:s]
    assert_equal({s: "NestedFileAnnotation"}, fileopt[:sub])
    assert_equal({__extensions: {"proto2_unittest.fileopt" => {s: "FileExtensionAnnotation"}}}, fileopt[:file])
    any = fileopt[:any]
    assert_equal "type.googleapis.com/proto2_unittest.AggregateMessageSetElement", any[:type_url]
    assert_equal "\n\x19EmbeddedMessageSetElement".b, any[:value]
  end

  private

  def each_options(hash, golden, type, path = [], &block)
    yield type, hash[:options], golden.options, path if hash.key?(:options)
    OPTIONS.each do |key, child_type|
      Array(hash[key]).each_with_index do |child, i|
        each_options(child, golden[key.to_s][i], child_type, path + [key, i], &block)
      end
    end
  end

  # Prints an options hash in protobuf's JSON mapping, extensions as "[name]"
  class OptionJson
    INT64 = %i[int64 uint64 sint64 fixed64 sfixed64].freeze

    def initialize(compiler, golden_pool)
      @pool = compiler.pool
      @compiler = compiler
      @golden_pool = golden_pool
    end

    def message(hash, type_name)
      type = @pool.find_message("google.protobuf.#{type_name}") ||
        @compiler.builtin_options_type("google.protobuf.#{type_name}")
      fields(hash, type)
    end

    private

    def fields(hash, type)
      out = {}
      hash.each do |key, value|
        if key == :__extensions
          value.each do |name, v|
            field = @pool.find_symbol(name)
            out["[#{name}]"] = value_of(field, v)
          end
        elsif key != :__unknown_fields
          field = type.fields_by_name.fetch(key.to_s)
          out[field.json_name] = value_of(field, value)
        end
      end
      out
    end

    def value_of(field, value)
      return value.map { |v| single(field, v) } if field.repeated? && !field.map?
      if field.map?
        key = field.message_type.field("key")
        val = field.message_type.field("value")
        return value.to_h { |e| [single(key, e[:key]).to_s, single(val, e[:value])] }
      end
      single(field, value)
    end

    def single(field, value)
      case field.type
      when :message, :group
        if field.message_type.full_name == "google.protobuf.Any"
          name = value[:type_url].split("/").last
          klass = @golden_pool.lookup(name).msgclass
          JSON.parse(klass.encode_json(klass.decode(value[:value]))).merge("@type" => value[:type_url])
        else
          fields(value, field.message_type)
        end
      when *INT64 then value.to_s
      when :float, :double
        if value.nan?
          "NaN"
        elsif value.infinite?
          value.positive? ? "Infinity" : "-Infinity"
        else
          value
        end
      when :bytes then [value].pack("m0")
      when :enum then value.is_a?(Symbol) ? value.to_s : value
      else value
      end
    end
  end
end
