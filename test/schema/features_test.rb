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
    proto2 = SchemaFixtures.add(pool, {name: "p2.proto"})
    proto3 = SchemaFixtures.add(pool, {name: "p3.proto", syntax: "proto3"})
    e2024 = SchemaFixtures.add(pool, {name: "e.proto", syntax: "editions", edition: :EDITION_2024})
    assert_equal F.defaults(:EDITION_PROTO2), proto2.features
    assert_equal F.defaults(:EDITION_PROTO3), proto3.features
    assert_equal F.defaults(:EDITION_2024), e2024.features
  end

  def test_merge
    base = F.defaults(:EDITION_2023)
    assert_same base, base.merge(nil)
    assert_same base, base.merge({})
    assert_same base, base.merge(field_presence: :EXPLICIT)
    merged = base.merge(field_presence: :IMPLICIT, enum_type: :CLOSED)
    assert_equal :IMPLICIT, merged.field_presence
    assert_equal :CLOSED, merged.enum_type
    assert_equal :PACKED, merged.repeated_field_encoding
    assert merged.frozen?
    assert Ractor.shareable?(merged)
    assert_equal base.merge(field_presence: :IMPLICIT, enum_type: :CLOSED), merged
  end

  def inheritance_file
    hash = {
      name: "inherit.proto", syntax: "editions", edition: :EDITION_2023, package: "inh",
      options: {features: {enum_type: :CLOSED, __extensions: {"pb.test" => {file_feature: :VALUE7, multiple: :VALUE1}}}},
      message_type: [{
        name: "Outer",
        options: {features: {field_presence: :IMPLICIT, __extensions: {"pb.test" => {multiple: :VALUE2}}}},
        field: [
          {name: "plain", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32},
          {name: "own", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_INT32,
           options: {features: {field_presence: :EXPLICIT}}},
          {name: "member", number: 3, label: :LABEL_OPTIONAL, type: :TYPE_INT32, oneof_index: 0},
          {name: "reps", number: 4, label: :LABEL_REPEATED, type: :TYPE_INT32}
        ],
        oneof_decl: [{name: "choice", options: {features: {utf8_validation: :NONE}}}],
        nested_type: [{name: "Inner", field: [{name: "deep", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_STRING}]}],
        enum_type: [{name: "InnerEnum", value: [{name: "INNER_ZERO", number: 0}]}],
        extension_range: [{start: 100, end: 200, options: {features: {json_format: :LEGACY_BEST_EFFORT}}}],
        extension: [{name: "scoped_ext", number: 100, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: ".inh.Outer"}]
      }],
      enum_type: [{name: "Top", options: {features: {enum_type: :OPEN}},
                   value: [{name: "TOP_ZERO", number: 0, options: {features: {json_format: :LEGACY_BEST_EFFORT}}},
                     {name: "TOP_ONE", number: 1}]}],
      extension: [{name: "file_ext", number: 101, label: :LABEL_OPTIONAL, type: :TYPE_INT32, extendee: ".inh.Outer"}],
      service: [{name: "Svc", options: {features: {json_format: :LEGACY_BEST_EFFORT}},
                 method: [{name: "Call", input_type: ".inh.Outer", output_type: ".inh.Outer"}]}]
    }
    S::Builder.build(hash, pool: S::Pool.new)
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
    assert_equal :LEGACY_BEST_EFFORT, svc.method(:Call).features.json_format
  end

  def test_custom_features_merge_as_messages
    file = inheritance_file
    outer = file.find_message("inh.Outer")
    assert_equal({"pb.test" => {file_feature: :VALUE7, multiple: :VALUE1}}, file.features.extensions)
    assert_equal({"pb.test" => {file_feature: :VALUE7, multiple: :VALUE2}}, outer.features.extensions)
    assert_equal outer.features.extensions, outer.field("plain").features.extensions
    assert_equal :VALUE2, outer.features.to_h[:__extensions]["pb.test"][:multiple]
  end

  def test_unchanged_features_are_shared
    file = inheritance_file
    outer = file.find_message("inh.Outer")
    assert_same outer.features, outer.field("plain").features
    assert_same outer.field("plain").features, outer.field("reps").features
    assert_same outer.features, file.find_message("inh.Outer.Inner").features
  end

  def test_legacy_proto2_spellings_map_onto_features
    file = S::Builder.build({
      name: "legacy2.proto",
      message_type: [{name: "M", field: [
        {name: "req", number: 1, label: :LABEL_REQUIRED, type: :TYPE_INT32},
        {name: "grp", number: 2, label: :LABEL_OPTIONAL, type: :TYPE_GROUP, type_name: ".M.Grp"},
        {name: "packed", number: 3, label: :LABEL_REPEATED, type: :TYPE_INT32, options: {packed: true}},
        {name: "plain", number: 4, label: :LABEL_REPEATED, type: :TYPE_INT32},
        {name: "explicit_unpacked", number: 5, label: :LABEL_REPEATED, type: :TYPE_INT32, options: {packed: false}},
        {name: "strings", number: 6, label: :LABEL_REPEATED, type: :TYPE_STRING, options: {packed: true}}
      ], nested_type: [{name: "Grp"}]}]
    }, pool: S::Pool.new)
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
    file = S::Builder.build({
      name: "legacy3.proto", syntax: "proto3",
      message_type: [{name: "M", field: [
        {name: "opt", number: 1, label: :LABEL_OPTIONAL, type: :TYPE_INT32, oneof_index: 0, proto3_optional: true},
        {name: "expanded", number: 2, label: :LABEL_REPEATED, type: :TYPE_INT32, options: {packed: false}},
        {name: "packed", number: 3, label: :LABEL_REPEATED, type: :TYPE_DOUBLE}
      ], oneof_decl: [{name: "_opt"}]}]
    }, pool: S::Pool.new)
    m = file.find_message("M")
    assert_equal :EXPLICIT, m.field("opt").features.field_presence
    refute m.field("expanded").packed?
    assert m.field("packed").packed?
    assert m.oneofs.first.synthetic?
  end
end
