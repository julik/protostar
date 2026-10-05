# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class WellKnownShortNamesTest < Minitest::Test
  NAMES = %i[
    Any Duration Empty FieldMask Struct Value ListValue Timestamp
    DoubleValue FloatValue Int64Value UInt64Value Int32Value UInt32Value BoolValue StringValue BytesValue
  ].freeze

  def test_short_names_are_the_long_classes
    NAMES.each do |name|
      short = Protostar.const_get(name)
      assert_same Protostar::Google::Protobuf.const_get(name), short, name
    end
    assert_equal "google.protobuf.Timestamp", Protostar::Timestamp.descriptor.full_name
    assert_equal Time.at(5), Protostar::Timestamp.from_time(Time.at(5)).to_time
    assert_equal({"a" => 1.0}, Protostar::Struct.from_hash("a" => 1).to_h)
  end

  def test_require_loads_no_well_known_file_until_a_short_name_is_used
    script = <<~RUBY
      require "protostar"
      before = $LOADED_FEATURES.grep(%r{protostar/google/protobuf/}).size
      Protostar::Duration
      after = $LOADED_FEATURES.grep(%r{protostar/google/protobuf/}).map { |f| File.basename(f) }
      puts before, after.join(",")
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
    assert status.success?, err
    assert_equal "0\nduration_pb.rb\n", out
  end

  def test_ruby_struct_is_still_reachable_inside_the_namespace
    assert_kind_of ::Struct, Protostar::Compiler::Lexer::Token.new
  end
end
