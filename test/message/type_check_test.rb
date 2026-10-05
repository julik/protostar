# frozen_string_literal: true

require "test_helper"

class TypeCheckTest < Minitest::Test
  def setup
    @all = CodecFixtures.load("google/protobuf/unittest.proto")["proto2_unittest.TestAllTypes"]
    @m = @all.new
  end

  def test_integer_ranges
    {
      int32: [-2**31, 2**31 - 1], sint32: [-2**31, 2**31 - 1], sfixed32: [-2**31, 2**31 - 1],
      uint32: [0, 2**32 - 1], fixed32: [0, 2**32 - 1],
      int64: [-2**63, 2**63 - 1], sint64: [-2**63, 2**63 - 1], sfixed64: [-2**63, 2**63 - 1],
      uint64: [0, 2**64 - 1], fixed64: [0, 2**64 - 1]
    }.each do |type, (min, max)|
      field = :"optional_#{type}="
      @m.public_send(field, min)
      @m.public_send(field, max)
      assert_raises(Protostar::TypeError, "#{type} below range") { @m.public_send(field, min - 1) }
      assert_raises(Protostar::TypeError, "#{type} above range") { @m.public_send(field, max + 1) }
      assert_raises(Protostar::TypeError, "#{type} from a Float") { @m.public_send(field, 1.0) }
      assert_raises(Protostar::TypeError, "#{type} from a String") { @m.public_send(field, "1") }
    end
  end

  def test_type_error_is_a_ruby_type_error_naming_the_field
    error = assert_raises(TypeError) { @m.optional_int32 = 2**31 }
    assert_kind_of Protostar::TypeError, error
    assert_match "proto2_unittest.TestAllTypes.optional_int32", error.message
    assert_match "2147483648", error.message
  end

  def test_floats_accept_integers
    @m.optional_double = 3
    assert_equal 3.0, @m.optional_double
    assert_instance_of Float, @m.optional_double
    @m.optional_float = 1
    assert_equal 1.0, @m.optional_float
    assert_raises(Protostar::TypeError) { @m.optional_double = "1" }
    assert_raises(Protostar::TypeError) { @m.optional_float = nil.to_a }
  end

  def test_float_fields_hold_single_precision
    @m.optional_float = 0.1
    assert_equal [0.1].pack("e").unpack1("e"), @m.optional_float
    @m.optional_float = 1e40
    assert_equal Float::INFINITY, @m.optional_float
    @m.optional_float = Float::NAN
    assert @m.optional_float.nan?
    @m.optional_double = 0.1
    assert_equal 0.1, @m.optional_double
  end

  def test_bool_is_strict
    @m.optional_bool = true
    @m.optional_bool = false
    [0, 1, nil.to_s, "true", :yes].each do |v|
      assert_raises(Protostar::TypeError) { @m.optional_bool = v }
    end
  end

  def test_strings_must_be_valid_utf8
    @m.optional_string = "héllo"
    assert_equal "héllo", @m.optional_string
    assert @m.optional_string.frozen?
    @m.optional_string = "plain".b
    assert_equal Encoding::UTF_8, @m.optional_string.encoding
    @m.optional_string = "h\xC3\xA9".b
    assert_equal "hé", @m.optional_string
    @m.optional_string = (+"caf\xE9").force_encoding(Encoding::ISO_8859_1)
    assert_equal "café", @m.optional_string, "other encodings are transcoded"
    assert_raises(Protostar::TypeError) { @m.optional_string = "\xFF".b }
    assert_raises(Protostar::TypeError) { @m.optional_string = (+"\xFF").force_encoding(Encoding::UTF_8) }
    assert_raises(Protostar::TypeError) { @m.optional_string = :sym }
    assert_raises(Protostar::TypeError) { @m.optional_string = 1 }
  end

  def test_string_writer_copies_mutable_input
    s = +"abc"
    @m.optional_string = s
    s << "d"
    assert_equal "abc", @m.optional_string
  end

  def test_bytes_are_frozen_binary
    @m.optional_bytes = "é"
    assert_equal "é".b, @m.optional_bytes
    assert_equal Encoding::BINARY, @m.optional_bytes.encoding
    assert @m.optional_bytes.frozen?
    @m.optional_bytes = "\xFF".b
    assert_equal "\xFF".b, @m.optional_bytes
    assert_raises(Protostar::TypeError) { @m.optional_bytes = 1 }
  end

  def test_nil_clears
    @m.optional_int32 = 5
    @m.optional_int32 = nil
    refute @m.has_optional_int32?
    @m.optional_string = "x"
    @m.optional_string = nil
    assert_equal "", @m.optional_string
  end

  def test_repeated_elements_are_checked
    assert_raises(Protostar::TypeError) { @m.repeated_uint32 = [1, -1] }
    assert_raises(Protostar::TypeError) { @m.repeated_string = ["\xFF".b] }
    assert_raises(Protostar::TypeError) { @m.repeated_nested_message = [1] }
    assert_raises(Protostar::TypeError) { @m.repeated_nested_enum = [:NOPE] }
    @m.repeated_float = [1, 0.1]
    assert_equal [1.0, [0.1].pack("e").unpack1("e")], @m.repeated_float
  end

  def test_values_pushed_into_containers_are_checked_on_encode
    @m.repeated_int32 << "nope"
    error = assert_raises(Protostar::EncodeError) { @m.encode }
    assert_match "repeated_int32", error.message
    @m.repeated_int32.clear
    @m.repeated_int32 << 2**40
    assert_raises(Protostar::EncodeError) { @m.encode }
  end
end
