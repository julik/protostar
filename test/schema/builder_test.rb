# frozen_string_literal: true

require "test_helper"

class BuilderTest < Minitest::Test
  S = Protostar::Schema

  def build(hash, pool = S::Pool.new)
    S::Builder.build(hash, pool: pool)
  end

  def field(name, number, type, **rest)
    {name: name, number: number, label: :LABEL_OPTIONAL, type: type, **rest}
  end

  def test_json_name_rule
    assert_equal "fooBar", S::Builder.json_name("foo_bar")
    assert_equal "fooBar", S::Builder.json_name("foo__bar")
    assert_equal "FooBar", S::Builder.json_name("_foo_bar")
    assert_equal "foo1", S::Builder.json_name("foo_1")
    assert_equal "fooBAR", S::Builder.json_name("foo_BAR")
    assert_equal "foo", S::Builder.json_name("foo_")
  end

  def test_computes_missing_json_names_and_keeps_declared_ones
    file = build(name: "j.proto", message_type: [{name: "M", field: [
      field("snake_case_name", 1, :TYPE_INT32),
      field("custom", 2, :TYPE_INT32, json_name: "Different")
    ]}])
    m = file.find_message("M")
    assert_equal "snakeCaseName", m.field(1).json_name
    assert_equal "snakeCaseName", m.field(1).to_h[:json_name]
    assert_equal "Different", m.field(2).json_name
    assert_same m.field(2), m.fields_by_json_name["Different"]
  end

  def test_options_round_trip_with_extensions_and_unknown_fields
    options = {
      deprecated: true,
      features: {field_presence: :EXPLICIT},
      __extensions: {"my.pkg.opt" => {nested: +"value", list: [1, 2]}, "my.pkg.flag" => true},
      __unknown_fields: [[50_000, 2, "\x01\x02".b], [50_001, 0, "\x96\x01".b]]
    }
    hash = {name: "o.proto", syntax: "editions", edition: :EDITION_2023,
            message_type: [{name: "M", options: options, field: [field("f", 1, :TYPE_INT32, json_name: "f")]}]}
    file = build(hash)
    m = file.find_message("M")
    assert_equal hash, file.to_h
    assert_equal true, m.options[:deprecated]
    assert m.options.key?(:deprecated)
    assert_equal true, m.options.fetch(:deprecated)
    assert_equal :none, m.options.fetch(:map_entry, :none)
    assert_equal({nested: "value", list: [1, 2]}, m.options.extensions["my.pkg.opt"])
    assert_equal [50_000, 2, "\x01\x02".b], m.options.unknown_fields.first
    assert_equal({field_presence: :EXPLICIT}, m.options.features)
    refute m.options.empty?
    assert Ractor.shareable?(m.options)
    refute options[:__extensions]["my.pkg.opt"][:nested].frozen?, "the caller's strings stay theirs"

    plain = m.field(1).options
    assert_same S::Options::EMPTY, plain
    assert_equal({}, plain.extensions)
    assert_equal [], plain.unknown_fields
    assert_nil plain.features
  end

  def test_integer_editions_are_named
    file = build(name: "e.proto", syntax: "editions", edition: 1002)
    assert_equal :EDITION_2026, file.edition
    assert_equal :EDITION_2026, file.to_h[:edition]
  end

  def test_names_without_leading_dot_are_normalised_in_to_h
    file = build(name: "n.proto", package: "p", message_type: [
      {name: "A"},
      {name: "B", field: [{name: "a", number: 1, label: :LABEL_OPTIONAL, type_name: "A"}]}
    ])
    assert_equal ".p.A", file.find_message("p.B").field(1).to_h[:type_name]
    assert_equal :TYPE_MESSAGE, file.find_message("p.B").field(1).to_h[:type]
  end

  def test_default_value_parsing
    file = build(name: "d.proto", message_type: [{name: "M", field: [
      field("hex", 1, :TYPE_INT32, default_value: "0x1F"),
      field("neg_hex", 2, :TYPE_INT64, default_value: "-0x10"),
      field("bytes_hex", 3, :TYPE_BYTES, default_value: "\\x41\\x4a\\101\\7\\0"),
      field("flt", 4, :TYPE_FLOAT, default_value: "0.1"),
      field("dbl", 5, :TYPE_DOUBLE, default_value: "0.1"),
      field("no", 6, :TYPE_BOOL, default_value: "false"),
      field("empty", 7, :TYPE_STRING, default_value: ""),
      field("high_bytes", 8, :TYPE_BYTES, default_value: "\\377\\200")
    ]}])
    m = file.find_message("M")
    assert_equal 31, m.field("hex").default_value
    assert_equal(-16, m.field("neg_hex").default_value)
    assert_equal "AJA\a\0".b, m.field("bytes_hex").default_value
    assert_equal 0.10000000149011612, m.field("flt").default_value
    assert_equal 0.1, m.field("dbl").default_value
    assert_equal false, m.field("no").default_value
    assert_equal false, m.field("no").default
    assert_equal "", m.field("empty").default_value
    assert_equal "\xFF\x80".b, m.field("high_bytes").default_value
    assert_equal "0x1F", m.field("hex").to_h[:default_value]
  end

  def test_invalid_defaults_raise
    [
      field("x", 1, :TYPE_INT32, default_value: "12abc"),
      field("x", 1, :TYPE_BOOL, default_value: "yes"),
      field("x", 1, :TYPE_DOUBLE, default_value: "fast"),
      field("x", 1, :TYPE_BYTES, default_value: "\\q"),
      {name: "x", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_ENUM, type_name: ".E", default_value: "NOPE"}
    ].each do |f|
      hash = {name: "bad.proto", message_type: [{name: "M", field: [f]}],
              enum_type: [{name: "E", value: [{name: "E0", number: 0}]}]}
      assert_raises(S::Error, f.inspect) { build(hash) }
    end
  end

  def test_missing_dependency
    error = assert_raises(S::Error) { build(name: "a.proto", dependency: ["missing.proto"]) }
    assert_includes error.message, "\"missing.proto\" is not in the pool"
  end

  def test_malformed_hashes
    {
      "not a hash" => "a.proto",
      "no name" => {package: "x"},
      "unknown file key" => {name: "a.proto", bogus: 1},
      "unknown message key" => {name: "a.proto", message_type: [{name: "M", fields: []}]},
      "string keys" => {"name" => "a.proto"},
      "name not a string" => {name: :a},
      "repeated not an array" => {name: "a.proto", message_type: {name: "M"}},
      "field without number" => {name: "a.proto", message_type: [{name: "M", field: [{name: "f", type: :TYPE_INT32}]}]},
      "unknown type" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT128)]}]},
      "unknown label" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT32, label: :LABEL_MAYBE)]}]},
      "message without type_name" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_MESSAGE)]}]},
      "scalar with type_name" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT32, type_name: ".M")]}]},
      "bad oneof index" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT32, oneof_index: 3)]}]},
      "extension without extendee" => {name: "a.proto", extension: [field("f", 1, :TYPE_INT32)]},
      "field with extendee" => {name: "a.proto", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT32, extendee: ".M")]}]},
      "bad public dependency" => {name: "a.proto", public_dependency: [0]},
      "unknown syntax" => {name: "a.proto", syntax: "proto4"},
      "editions without edition" => {name: "a.proto", syntax: "editions"},
      "proto3 with edition" => {name: "a.proto", syntax: "proto3", edition: :EDITION_2023},
      "unknown edition" => {name: "a.proto", syntax: "editions", edition: :EDITION_3000},
      "duplicate symbol" => {name: "a.proto", message_type: [{name: "M"}, {name: "M"}]},
      "options not a hash" => {name: "a.proto", options: [1]},
      "range without end" => {name: "a.proto", message_type: [{name: "M", extension_range: [{start: 1}]}]},
      "object in options" => {name: "a.proto", options: {java_package: Object.new}}
    }.each do |what, hash|
      assert_raises(S::Error, what) { build(hash) }
    end
  end

  def test_extendee_must_be_a_message
    hash = {name: "a.proto", enum_type: [{name: "E", value: [{name: "Z", number: 0}]}],
            extension: [{name: "x", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: ".E"}]}
    assert_raises(S::ResolveError) { build(hash) }
  end

  def test_minimal_file
    file = build(name: "empty.proto")
    assert_equal "", file.package
    assert_equal :proto2, file.syntax
    assert_nil file.edition
    assert_equal [], file.messages
    assert_equal({name: "empty.proto"}, file.to_h)
    assert_same file, file.file
    assert_equal "#<Protostar::Schema::File empty.proto>", file.inspect
  end

  def test_reserved_ranges_and_visibility_round_trip
    hash = {
      name: "r.proto", syntax: "editions", edition: :EDITION_2024,
      message_type: [{name: "M", reserved_range: [{start: 1, end: 3}, {start: 10, end: 11}],
                      reserved_name: ["old"], visibility: :VISIBILITY_EXPORT}],
      enum_type: [{name: "E", value: [{name: "E_ZERO", number: 0}], reserved_range: [{start: 5, end: 9}],
                   reserved_name: ["GONE"], visibility: :VISIBILITY_LOCAL}]
    }
    file = build(hash)
    assert_equal hash, file.to_h
    assert_equal [1..2, 10..10], file.find_message("M").reserved_ranges
    assert_equal [5..9], file.find_enum("E").reserved_ranges, "enum reserved ranges are inclusive"
    assert_equal :VISIBILITY_EXPORT, file.find_message("M").visibility
  end

  def test_label_and_type_are_never_missing_from_to_h
    file = build(name: "l.proto", message_type: [{name: "M", field: [{name: "f", number: 1, type: :TYPE_INT32}]}])
    f = file.find_message("M").field(1)
    assert_equal :optional, f.label
    assert_equal({name: "f", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32, json_name: "f"}, f.to_h)
  end

  def test_inspect_is_short
    file = build(name: "i.proto", package: "p", message_type: [{name: "M", field: [field("f", 1, :TYPE_INT32)]}])
    assert_equal "#<Protostar::Schema::Field p.M.f>", file.find_message("p.M").field(1).inspect
  end
end
