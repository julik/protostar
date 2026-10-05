# frozen_string_literal: true

require "test_helper"

# Schema::Options: readers for descriptor.proto's option fields, custom
# options by extension, unknown bytes and resolved features
class OptionsTest < Minitest::Test
  S = Protostar::Schema

  def pool_with_custom_options
    pool = S::Pool.new
    Protostar::Compiler.new(pool: pool).compile(["google/protobuf/descriptor.proto"], retain_options: true)
    file = S::File.draft("my.proto", package: "my.pkg", dependencies: ["google/protobuf/descriptor.proto"])
    file.message("Opt") do |m|
      m.field "nested", 1, :string
      m.field "list", 2, :int32, label: :repeated
    end
    file.extend(".google.protobuf.MessageOptions") do |e|
      e.field "opt", 50_100, "Opt"
      e.field "flag", 50_101, :bool
    end
    pool.add(file.resolve(pool).freeze!)
    pool
  end

  def test_readers_extensions_unknown_fields_and_features
    pool = pool_with_custom_options
    nested = +"value"
    file = S::File.draft("o.proto", edition: :EDITION_2023, dependencies: ["my.proto"])
    file.message("M", options: {
      deprecated: true,
      features: {field_presence: :IMPLICIT},
      extensions: {"my.pkg.opt" => {nested: nested, list: [1, 2]}, "my.pkg.flag" => true},
      unknown_fields: "\x82\xb5\x18\x02\x01\x02".b
    }) { |m| m.field "f", 1, :int32 }
    built = file.resolve(pool).freeze!
    options = built.find_message("M").options

    assert_kind_of S::MessageOptions, options
    assert_equal "google.protobuf.MessageOptions", options.type_name
    assert_equal true, options.deprecated
    assert options.deprecated?
    assert_nil options.map_entry
    refute options.map_entry?
    assert options.key?(:deprecated)
    refute options.key?(:map_entry)
    assert_equal true, options[:deprecated]

    opt = pool.find_symbol("my.pkg.opt")
    value = options.extension(opt)
    assert_kind_of S::MessageValue, value
    assert_equal "value", value[:nested]
    assert_equal [1, 2], value[:list]
    assert_same value, options.extension("my.pkg.opt")
    assert_equal true, options.extension(".my.pkg.flag")
    assert_equal [opt, pool.find_symbol("my.pkg.flag")], options.extensions.keys
    assert_equal "\x82\xb5\x18\x02\x01\x02".b, options.unknown_fields

    assert_equal S::MessageValue.new({field_presence: :IMPLICIT}), options[:features]
    assert_kind_of S::Features, options.features
    assert_same built.find_message("M").features, options.features
    assert_equal :IMPLICIT, options.features.field_presence
    refute options.empty?
    assert options.declared?
    assert Ractor.shareable?(options)
    refute nested.frozen?, "the caller's strings stay theirs"

    plain = built.find_message("M").field(1).options
    assert_kind_of S::FieldOptions, plain
    assert plain.empty?
    refute plain.declared?
    assert_equal({}, plain.extensions)
    assert_equal "", plain.unknown_fields
    assert_equal [], plain.targets
    assert_same built.find_message("M").field(1).features, plain.features
  end

  def test_unknown_extension_names_are_refused
    file = S::File.draft("x.proto")
    file.message("M", options: {extensions: {"no.such.option" => 1}})
    error = assert_raises(S::Error) { file.resolve(S::Pool.new) }
    assert_match(/no.such.option/, error.message)
  end

  def test_readers_match_descriptor_proto
    descriptor = Protostar::Compiler.new.compile(["google/protobuf/descriptor.proto"]).last
    [S::FileOptions, S::MessageOptions, S::FieldOptions, S::OneofOptions, S::EnumOptions, S::EnumValueOptions,
      S::ServiceOptions, S::MethodOptions, S::ExtensionRangeOptions].each do |klass|
      type = descriptor.find_message(klass.type_name)
      names = type.fields.map { |f| f.name.to_sym } - [:uninterpreted_option]
      assert_equal names.sort, klass::FIELDS.sort, klass.type_name
      type.fields.each do |f|
        next if f.name == "uninterpreted_option"
        assert klass.method_defined?(f.name), "#{klass.type_name}##{f.name}"
        assert klass.method_defined?(:"#{f.name}?"), "#{klass.type_name}##{f.name}?" if f.type == :bool
      end
    end
  end

  def test_message_value_merge
    a = S::MessageValue.new({x: 1, inner: S::MessageValue.new({p: 1}), list: [1]})
    b = S::MessageValue.new({y: 2, inner: S::MessageValue.new({q: 2}), list: [2]})
    merged = a.merge(b)
    assert_equal 1, merged[:x]
    assert_equal 2, merged[:y]
    assert_equal S::MessageValue.new({p: 1, q: 2}), merged[:inner]
    assert_equal [1, 2], merged[:list]
    assert_same a, a.merge(nil)
    assert_equal({x: 1, inner: {p: 1}, list: [1]}, a.to_h)
  end
end
