# frozen_string_literal: true

require "test_helper"

# The native emitter on descriptors the corpus does not have: layouts the
# DSL's sugar cannot say, which must fall back to plain calls and still
# rebuild the same descriptors
class RubyEmitterTest < Minitest::Test
  Emitters = Protostar::Compiler::Emitters
  # A file from a FileDescriptorProto hash; file options may carry
  # `__unknown_fields` as [number, wire type, bytes]
  def build(hash)
    unknown = hash.dig(:options, :__unknown_fields)
    hash = hash.merge(options: hash[:options].except(:__unknown_fields)) if unknown
    proto = Protostar::Schema::Proto.types::FileDescriptorProto.new(hash)
    if unknown
      bytes = proto.options.encode + Protostar::Schema::MessageValue.unknown_bytes(unknown)
      proto.options = proto.options.class.decode(bytes)
    end
    Protostar::Schema::File.from_proto(proto, pool: Protostar::Schema::Pool.new)
  end

  def round_trip(hash)
    built = build(hash)
    source = Emitters::Ruby.new.definition(built)
    pool = Protostar::Schema::Pool.new
    saved = Protostar.generated_pool
    Protostar.instance_variable_set(:@generated_pool, pool)
    begin
      eval(source, TOPLEVEL_BINDING, "(emitted)") # rubocop:disable Security/Eval
    ensure
      Protostar.instance_variable_set(:@generated_pool, saved)
    end
    assert_equal built.serialize, pool.file(built.name).serialize, source
    source
  end

  def field(name, number, extra = {})
    {name: name, number: number, label: :LABEL_OPTIONAL, type: :TYPE_INT32}.merge(extra)
  end

  def test_oneofs_out_of_order_are_declared_up_front
    source = round_trip(name: "rt/a.proto", package: "rt.a", message_type: [{
      name: "M", field: [field("a", 1, oneof_index: 1), field("b", 2, oneof_index: 0), field("c", 3, oneof_index: 1)],
      oneof_decl: [{name: "x"}, {name: "y"}]
    }])
    assert_includes source, "m.oneof :x\n"
    assert_includes source, "m.field :a, 1, :int32, oneof: :y\n"
  end

  def test_synthetic_oneof_with_an_unusual_name
    source = round_trip(name: "rt/b.proto", package: "rt.b", syntax: "proto3", message_type: [{
      name: "M", field: [field("a", 1, oneof_index: 0, proto3_optional: true)], oneof_decl: [{name: "custom"}]
    }])
    assert_includes source, "proto3_optional: true, oneof: :custom"
  end

  def test_canonical_synthetic_oneofs_are_left_to_the_dsl
    source = round_trip(name: "rt/c.proto", package: "rt.c", syntax: "proto3", message_type: [{
      name: "M", field: [field("a", 1, oneof_index: 0), field("_b", 2, oneof_index: 1, proto3_optional: true)],
      oneof_decl: [{name: "_a"}, {name: "X_b"}]
    }])
    refute_includes source, "X_b"
  end

  def test_map_entries_the_sugar_cannot_say
    entry = {name: "TagsEntry", field: [field("key", 1, json_name: "key", type: :TYPE_STRING),
      field("value", 2, json_name: "value")], options: {map_entry: true, deprecated: true}}
    source = round_trip(name: "rt/d.proto", package: "rt.d", message_type: [{
      name: "M", nested_type: [entry],
      field: [field("tags", 1, label: :LABEL_REPEATED, type: :TYPE_MESSAGE, type_name: ".rt.d.M.TagsEntry")]
    }])
    refute_includes source, "m.map"
    assert_includes source, "map_entry: true"
  end

  def test_map_entries_keep_their_place_among_nested_messages
    entry = {name: "TagsEntry", field: [field("key", 1, json_name: "key", type: :TYPE_STRING),
      field("value", 2, json_name: "value")], options: {map_entry: true}}
    source = round_trip(name: "rt/e.proto", package: "rt.e", message_type: [{
      name: "M", nested_type: [{name: "A"}, entry, {name: "B"}],
      field: [field("tags", 1, label: :LABEL_REPEATED, type: :TYPE_MESSAGE, type_name: ".rt.e.M.TagsEntry")]
    }])
    assert_operator source.index("m.message \"A\""), :<, source.index("m.map :tags")
    assert_operator source.index("m.map :tags"), :<, source.index("m.message \"B\"")
  end

  def test_literals
    source = round_trip(name: "rt/f.proto", package: "rt.f", options: {
      java_package: "a\"b\\c\#{x}\n\u00e9\u200b", __unknown_fields: [[5000, 2, "\x01\xff".b]]
    }, message_type: [{name: "M", field: [
      field("f", 1, type: :TYPE_DOUBLE, default_value: "inf"),
      field("b", 2, type: :TYPE_BYTES, default_value: "\\377")
    ]}])
    assert_includes source, '\#{x}'
    assert_includes source, "\\u{200B}"
    assert_includes source, 'unknown_fields: "\xC2\xB8\x02\x01\xFF".b'
  end

  def test_comments_come_from_source_info
    proto = <<~PROTO
      syntax = "proto3";
      package rt.g;
      // A message.
      //
      // Over two paragraphs.
      message M {
        // A field.
        int32 a = 1;
        // A oneof.
        oneof o { int32 b = 2; }
      }
      // An enum.
      enum E { Z = 0; }
      // A service.
      service S {
        // A method.
        rpc Call(M) returns (M);
      }
    PROTO
    file = Protostar::Compiler.new.compile(["rt/g.proto"], sources: {"rt/g.proto" => proto}, source_info: true).last
    source = Emitters::Ruby.new.file(file)
    ["  # A message.\n  #\n  # Over two paragraphs.\n  f.message", "    # A field.\n", "    # A oneof.\n    m.oneof",
      "  # An enum.\n", "  # A service.\n", "    # A method.\n    s.rpc :Call"].each do |text|
      assert_includes source, text
    end
  end

  def test_constants_follow_protoc
    proto = <<~PROTO
      syntax = "proto3";
      package foo_bar.baz;
      message lower { message _under { } enum e { Z = 0; } map<string, int32> m = 1; }
    PROTO
    file = Protostar::Compiler.new.compile(["c.proto"], sources: {"c.proto" => proto}).last
    source = Emitters::Ruby.new.file(file)
    assert_includes source, "module FooBar\n  module Baz\n"
    assert_includes source, "Lower = Protostar::DSL.message(\"foo_bar.baz.lower\")"
    assert_includes source, "Lower::PB__under = Protostar::DSL.message(\"foo_bar.baz.lower._under\")"
    assert_includes source, "Lower::E = Protostar::DSL.enum(\"foo_bar.baz.lower.e\")"
    refute_includes source, "MEntry ="
  end

  def test_namespaces_and_requires
    proto = "syntax = \"proto3\"; package a; import \"google/protobuf/timestamp.proto\"; import \"b/c.proto\";" \
      " message M { google.protobuf.Timestamp t = 1; b.C c = 2; }"
    dep = "syntax = \"proto3\"; package b; message C {}"
    file = Protostar::Compiler.new.compile(["a.proto"], sources: {"a.proto" => proto, "b/c.proto" => dep}).last
    source = Emitters::Ruby.new(namespaces: {"a.proto" => "X::Y"}).file(file)
    assert_includes source, "require \"protostar/google/protobuf/timestamp_pb\"\nrequire \"b/c_pb\"\n"
    assert_includes source, "module X\n  module Y\n    M = "
    plain = Emitters::Ruby.new(bootstrap_requires: false).file(file)
    assert_includes plain, "require \"google/protobuf/timestamp_pb\"\n"
  end

  def test_options_from_import_option_files_are_written_as_bytes
    opts = <<~PROTO
      edition = "2024";
      package rt.io.opts;
      import "google/protobuf/descriptor.proto";
      extend google.protobuf.MessageOptions { int32 level = 50001; }
    PROTO
    user = <<~PROTO
      edition = "2024";
      package rt.io.app;
      import option "rt/io/opts.proto";
      message M { option (rt.io.opts.level) = 7; option deprecated = true; }
    PROTO
    sources = {"rt/io/opts.proto" => opts, "rt/io/app.proto" => user}
    file = Protostar::Compiler.new.compile(["rt/io/app.proto"], sources: sources).last
    source = Emitters::Ruby.new.definition(file)
    assert_includes source, 'f.message "M", deprecated: true, unknown_fields: "\x88\xB5\x18\a".b'
    refute_includes source, "opts.level"
    pool = Protostar::Schema::Pool.new
    saved = Protostar.generated_pool
    Protostar.instance_variable_set(:@generated_pool, pool)
    begin
      eval(source, TOPLEVEL_BINDING, "(emitted)") # rubocop:disable Security/Eval
    ensure
      Protostar.instance_variable_set(:@generated_pool, saved)
    end
    loaded = pool.file("rt/io/app.proto")
    assert_equal "\x88\xb5\x18\x07".b, loaded.messages.first.options.unknown_fields
    assert loaded.messages.first.options.deprecated?
    assert_equal file.serialize(source_info: false), loaded.serialize
  end
end
