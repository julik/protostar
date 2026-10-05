# frozen_string_literal: true

require "test_helper"

class FeaturesTest < Minitest::Test
  S = Protostar::Schema
  F = S::Features

  def test_defaults_match_the_edition_defaults_annotations_in_descriptor_proto
    descriptor = GoldenHash.load(Corpus.golden("google/protobuf/descriptor.proto", :json)).last
    feature_set = descriptor[:message_type].find { |m| m[:name] == "FeatureSet" }
    annotated = feature_set[:field].to_h do |field|
      pairs = field[:options][:edition_defaults].map { |d| [d[:edition], d[:value].to_sym] }
      [field[:name].to_sym, pairs]
    end
    assert_equal annotated, F::DEFAULTS
  end

  def test_edition_numbers_match_descriptor_proto
    descriptor = GoldenHash.load(Corpus.golden("google/protobuf/descriptor.proto", :json)).last
    edition = descriptor[:enum_type].find { |e| e[:name] == "Edition" }
    assert_equal edition[:value].to_h { |v| [v[:name].to_sym, v[:number]] }, F::EDITIONS
  end

  # The expectations of FeaturesTest.Proto2Features, Proto3Features and
  # Edition20{23,24,26}Defaults in descriptor_unittest.cc
  def test_defaults_per_edition
    legacy = {field_presence: :EXPLICIT, enum_type: :CLOSED, repeated_field_encoding: :EXPANDED,
              utf8_validation: :NONE, message_encoding: :LENGTH_PREFIXED, json_format: :LEGACY_BEST_EFFORT,
              enforce_naming_style: :STYLE_LEGACY, default_symbol_visibility: :EXPORT_ALL,
              enforce_proto_limits: :LEGACY_NO_EXPLICIT_LIMITS}
    proto3 = legacy.merge(field_presence: :IMPLICIT, enum_type: :OPEN, repeated_field_encoding: :PACKED,
      utf8_validation: :VERIFY, json_format: :ALLOW)
    e2023 = proto3.merge(field_presence: :EXPLICIT)
    e2024 = e2023.merge(enforce_naming_style: :STYLE2024, default_symbol_visibility: :EXPORT_TOP_LEVEL)
    e2026 = e2024.merge(enforce_naming_style: :STYLE2026, default_symbol_visibility: :STRICT,
      enforce_proto_limits: :PROTO_LIMITS2026)

    assert_equal legacy, F.defaults(:EDITION_PROTO2).to_h
    assert_equal proto3, F.defaults(:EDITION_PROTO3).to_h
    assert_equal e2023, F.defaults(:EDITION_2023).to_h
    assert_equal e2024, F.defaults(:EDITION_2024).to_h
    assert_equal e2026, F.defaults(:EDITION_2026).to_h
    assert_equal e2026, F.defaults(:EDITION_UNSTABLE).to_h
    assert_equal e2023, F.defaults(1000).to_h
  end

  def test_unknown_or_too_early_editions_raise
    assert_raises(S::Error) { F.defaults(:EDITION_1984) }
    assert_raises(S::Error) { F.defaults(:EDITION_1_TEST_ONLY) }
  end

  def test_files_resolve_as_their_syntax
    pool = S::Pool.new
    proto2 = SchemaFixtures.add(pool, "p2.proto")
    proto3 = SchemaFixtures.add(pool, "p3.proto", syntax: :proto3)
    e2024 = SchemaFixtures.add(pool, "e.proto", edition: :EDITION_2024)
    assert_equal F.defaults(:EDITION_PROTO2), proto2.features
    assert_equal F.defaults(:EDITION_PROTO3), proto3.features
    assert_equal F.defaults(:EDITION_2024), e2024.features
  end

  def test_merge
    base = F.defaults(:EDITION_2023)
    declared = ->(**fields) { S::MessageValue.new(fields) }
    assert_same base, base.merge(nil)
    assert_same base, base.merge(declared.call)
    assert_same base, base.merge(declared.call(field_presence: :EXPLICIT))
    merged = base.merge(declared.call(field_presence: :IMPLICIT, enum_type: :CLOSED))
    assert_equal :IMPLICIT, merged.field_presence
    assert_equal :CLOSED, merged.enum_type
    assert_equal :PACKED, merged.repeated_field_encoding
    assert merged.frozen?
    assert Ractor.shareable?(merged)
    assert_equal base.with(field_presence: :IMPLICIT, enum_type: :CLOSED), merged
    assert_same base, base.with(field_presence: :EXPLICIT)
  end

  # A custom feature set `pb.test`, as unittest_features.proto declares one
  def custom_features(pool)
    Protostar::Compiler.new(pool: pool).compile(["google/protobuf/descriptor.proto"], retain_options: true)
    file = S::File.draft("pbtest.proto", package: "pb", dependencies: ["google/protobuf/descriptor.proto"])
    file.enum("EnumFeature") { |e| %i[VALUE0 VALUE1 VALUE2 VALUE7].each_with_index { |v, i| e.value(v, i) } }
    file.message("TestFeatures") do |m|
      m.field "file_feature", 1, "EnumFeature"
      m.field "multiple", 2, "EnumFeature"
    end
    file.extend(".google.protobuf.FeatureSet") { |e| e.field "test", 9999, "TestFeatures" }
    pool.add(file.resolve(pool).freeze!)
  end

  def inheritance_file
    pool = S::Pool.new
    custom_features(pool)
    file = S::File.draft("inherit.proto", edition: :EDITION_2023, package: "inh", dependencies: ["pbtest.proto"],
      options: {features: {enum_type: :CLOSED, extensions: {"pb.test" => {file_feature: :VALUE7, multiple: :VALUE1}}}})
    file.message("Outer", options: {features: {field_presence: :IMPLICIT,
                                               extensions: {"pb.test" => {multiple: :VALUE2}}}}) do |m|
      m.field "plain", 1, :int32
      m.field "own", 2, :int32, options: {features: {field_presence: :EXPLICIT}}
      m.oneof("choice", options: {features: {utf8_validation: :NONE}}) { |o| o.field "member", 3, :int32 }
      m.field "reps", 4, :int32, label: :repeated
      m.message("Inner") { |i| i.field "deep", 1, :string }
      m.enum("InnerEnum") { |e| e.value "INNER_ZERO", 0 }
      m.extensions 100..199, options: {features: {json_format: :LEGACY_BEST_EFFORT}}
      m.extend(".inh.Outer") { |e| e.field "scoped_ext", 100, :int32 }
    end
    file.enum("Top", options: {features: {enum_type: :OPEN}}) do |e|
      e.value "TOP_ZERO", 0, options: {features: {json_format: :LEGACY_BEST_EFFORT}}
      e.value "TOP_ONE", 1
    end
    file.extend(".inh.Outer") { |e| e.field "file_ext", 101, :int32 }
    file.service("Svc", options: {features: {json_format: :LEGACY_BEST_EFFORT}}) do |s|
      s.rpc "Call", ".inh.Outer", ".inh.Outer"
    end
    file.resolve(pool).freeze!
  end

  def test_inheritance
    file = inheritance_file
    outer = file.find_message("inh.Outer")
    assert_equal :CLOSED, file.features.enum_type
    assert_equal :IMPLICIT, outer.features.field_presence
    assert_equal :CLOSED, outer.features.enum_type, "message inherits from file"

    assert_equal :IMPLICIT, outer.field("plain").features.field_presence, "field inherits from message"
    refute outer.field("plain").presence?
    assert_equal :EXPLICIT, outer.field("own").features.field_presence, "field overrides"
    assert outer.field("own").presence?

    choice = outer.oneofs.first
    assert_equal :NONE, choice.features.utf8_validation
    assert_equal :NONE, outer.field("member").features.utf8_validation, "oneof member inherits from oneof"
    assert_equal :IMPLICIT, outer.field("member").features.field_presence
    assert outer.field("member").presence?, "oneof members have presence regardless"

    inner = file.find_message("inh.Outer.Inner")
    assert_equal :IMPLICIT, inner.features.field_presence, "nested message inherits from outer"
    assert_equal :IMPLICIT, inner.field("deep").features.field_presence
    assert inner.field("deep").utf8_validation?

    assert_equal :CLOSED, file.find_enum("inh.Outer.InnerEnum").features.enum_type
    assert file.find_enum("inh.Outer.InnerEnum").closed?
    top = file.find_enum("inh.Top")
    refute top.closed?
    assert_equal :OPEN, top.value(0).features.enum_type, "value inherits from enum"
    assert_equal :LEGACY_BEST_EFFORT, top.value(0).features.json_format
    assert_equal :ALLOW, top.value(1).features.json_format

    range = outer.extension_range_descriptors.first
    assert_equal :LEGACY_BEST_EFFORT, range.features.json_format
    assert_equal :IMPLICIT, range.features.field_presence
    assert_equal 100..199, range.range

    scoped = outer.extensions.first
    assert_equal :IMPLICIT, scoped.features.field_presence, "extension inherits from its declaring scope"
    assert scoped.presence?, "extensions always have presence"
    assert_equal :EXPLICIT, file.extensions.first.features.field_presence

    svc = file.services.first
    assert_equal :LEGACY_BEST_EFFORT, svc.features.json_format
    assert_equal :LEGACY_BEST_EFFORT, svc.rpc(:Call).features.json_format
  end

  def test_custom_features_merge_as_messages
    file = inheritance_file
    outer = file.find_message("inh.Outer")
    test = file.dependency_files.first.find_extension("pb.test")
    assert_equal({test => S::MessageValue.new({file_feature: :VALUE7, multiple: :VALUE1})}, file.features.extensions)
    assert_equal({test => S::MessageValue.new({file_feature: :VALUE7, multiple: :VALUE2})}, outer.features.extensions)
    assert_equal outer.features.extensions, outer.field("plain").features.extensions
    assert_equal :VALUE2, outer.features.extensions[test][:multiple]
  end

  def test_unchanged_features_are_shared
    file = inheritance_file
    outer = file.find_message("inh.Outer")
    assert_same outer.features, outer.field("plain").features
    assert_same outer.field("plain").features, outer.field("reps").features
    assert_same outer.features, file.find_message("inh.Outer.Inner").features
  end

  def test_legacy_proto2_spellings_map_onto_features
    file = S::File.draft("legacy2.proto")
    file.message("M") do |m|
      m.field "req", 1, :int32, label: :required
      m.group "Grp", 2
      m.field "packed", 3, :int32, label: :repeated, options: {packed: true}
      m.field "plain", 4, :int32, label: :repeated
      m.field "explicit_unpacked", 5, :int32, label: :repeated, options: {packed: false}
      m.field "strings", 6, :string, label: :repeated, options: {packed: true}
    end
    file = file.resolve(S::Pool.new).freeze!
    m = file.find_message("M")
    assert_equal :LEGACY_REQUIRED, m.field("req").features.field_presence
    assert m.field("req").required?
    assert_equal :DELIMITED, m.field("grp").features.message_encoding
    assert m.field("grp").delimited?
    assert m.field("packed").packed?
    refute m.field("plain").packed?
    refute m.field("explicit_unpacked").packed?
    refute m.field("strings").packed?, "strings cannot be packed whatever the option says"
  end

  def test_legacy_proto3_spellings_map_onto_features
    file = S::File.draft("legacy3.proto", syntax: :proto3)
    file.message("M") do |m|
      m.field "opt", 1, :int32, optional: true
      m.field "expanded", 2, :int32, label: :repeated, options: {packed: false}
      m.field "packed", 3, :double, label: :repeated
    end
    file = file.resolve(S::Pool.new).freeze!
    m = file.find_message("M")
    assert_equal :EXPLICIT, m.field("opt").features.field_presence
    refute m.field("expanded").packed?
    assert m.field("packed").packed?
    assert m.oneofs.first.synthetic?
  end
end
