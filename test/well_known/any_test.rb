# frozen_string_literal: true

require "test_helper"

class WellKnownAnyTest < Minitest::Test
  def setup
    @set = CodecFixtures.load("google/protobuf/any_test.proto")
    @any = @set["google.protobuf.Any"]
    @test_any = @set["proto2_unittest.TestAny"]
  end

  def test_mixin_is_applied_by_types_define
    assert_includes @any.ancestors, Protostar::WellKnown::Any
    assert_respond_to @any, :pack
    refute_includes @test_any.ancestors, Protostar::WellKnown::Any
    standalone = CodecFixtures.load("google/protobuf/any.proto")["google.protobuf.Any"]
    assert_includes standalone.ancestors, Protostar::WellKnown::Any
  end

  def test_pack_and_unpack
    inner = @test_any.new(int32_value: 5, text: "x")
    any = @any.pack(inner)
    assert_equal "type.googleapis.com/proto2_unittest.TestAny", any.type_url
    assert_equal inner.encode, any.value
    assert_equal "proto2_unittest.TestAny", any.type_name
    assert any.is(@test_any)
    refute any.is(@any)
    assert_equal inner, any.unpack(@test_any)
    assert_nil any.unpack(@any)
  end

  def test_type_url_prefixes
    inner = @test_any.new(int32_value: 1)
    assert_equal "example.com/types/proto2_unittest.TestAny", @any.pack(inner, "example.com/types/").type_url
    assert_equal "example.com/types/proto2_unittest.TestAny", @any.pack(inner, "example.com/types").type_url
    assert_equal "/proto2_unittest.TestAny", @any.pack(inner, "").type_url
    any = @any.new
    assert_same any, any.pack(inner, "x.y/")
    assert_equal "x.y/proto2_unittest.TestAny", any.type_url
    assert_equal inner, any.unpack(@test_any)
  end

  def test_any_through_json_with_the_registry
    any = @any.pack(@test_any.new(int32_value: 3), "my.domain/pkg")
    json = @any.encode_json(any, registry: @set.registry)
    assert_equal '{"@type":"my.domain/pkg/proto2_unittest.TestAny","int32Value":3}', json
    assert_equal any, @any.decode_json(json, registry: @set.registry)
    assert_raises(Protostar::JSON::EncodeError) { @any.encode_json(any) }
  end

  def test_any_through_the_process_wide_registry
    pool = Protostar::Schema::Pool.new
    file = SchemaFixtures.add(pool, "wkt_any_global.proto", package: "wkt_any_global", syntax: :proto3) do |f|
      f.message("Thing") { |m| m.field "n", 1, :int32 }
    end
    TestSupport.isolated_globals do
      thing = Protostar::Types.define(file).fetch("wkt_any_global.Thing")
      any = @any.pack(thing.new(n: 4))
      assert_equal '{"@type":"type.googleapis.com/wkt_any_global.Thing","n":4}', any.to_json
      assert_equal any, @any.decode_json(any.to_json)
    end
  end
end
