# frozen_string_literal: true

require "test_helper"

class RactorTest < Minitest::Test
  def test_descriptors_built_in_main_are_readable_in_another_ractor
    _, file = SchemaFixtures.load("google/protobuf/unittest.proto")
    assert Ractor.shareable?(file)

    experimental = Warning[:experimental]
    Warning[:experimental] = false
    ractor = begin
      Ractor.new(file) do |f|
        m = f.find_message("proto2_unittest.TestAllTypes")
        nested = m.field("optional_nested_message").message_type
        [
          m.fields.size,
          m.field(1).name,
          nested.full_name,
          nested.file.name,
          m.field("default_bytes").default_value,
          m.field("repeated_int32").packed?,
          f.find_enum("proto2_unittest.ForeignEnum").value(5).name,
          f.dependency_files.first.name,
          f.to_h[:name]
        ]
      end
    ensure
      Warning[:experimental] = experimental
    end
    result = ractor.respond_to?(:value) ? ractor.value : ractor.take

    m = file.find_message("proto2_unittest.TestAllTypes")
    assert_equal [m.fields.size, "optional_int32", "proto2_unittest.TestAllTypes.NestedMessage",
      "google/protobuf/unittest.proto", "world".b, false, "FOREIGN_BAR",
      "google/protobuf/unittest_import.proto", "google/protobuf/unittest.proto"], result
  end

  def test_everything_reachable_is_frozen
    _, file = SchemaFixtures.load("google/protobuf/unittest_proto3_optional.proto")
    seen = {}.compare_by_identity
    stack = [file]
    until stack.empty?
      obj = stack.pop
      next if seen.key?(obj)
      seen[obj] = true
      assert obj.frozen?, "#{obj.class} is not frozen"
      case obj
      when Array then stack.concat(obj)
      when Hash then obj.each { |k, v| stack << k << v }
      else obj.instance_variables.each { |iv| stack << obj.instance_variable_get(iv) }
      end
    end
    assert_operator seen.size, :>, 1000
  end
end
