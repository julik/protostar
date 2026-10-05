# frozen_string_literal: true

require "test_helper"

# Schema::File.draft: what it builds is what the compiler builds from the
# equivalent .proto, byte for byte once serialized
class DraftTest < Minitest::Test
  S = Protostar::Schema

  def setup
    @pool = S::Pool.new
  end

  def compiled(name, source)
    compiler = Protostar::Compiler.new(pool: @pool)
    compiler.compile([name], sources: {name => source}, retain_options: true).last
  end

  def assert_same_descriptor(expected, actual)
    assert_equal expected.serialize(source_info: false), actual.serialize(source_info: false)
  end

  def test_the_shop_example
    file = S::File.draft("shop.proto", package: "shop", syntax: :proto3)
    item = file.message("Item") do |m|
      m.field "name", 1, :string
      m.field "price_cents", 2, :int64, optional: true
      m.map "stock", 3, key: :string, value: :int32
    end
    assert_kind_of S::Message, item.descriptor
    built = file.resolve(@pool).freeze!

    assert Ractor.shareable?(built)
    assert_same built, file.descriptor
    m = built.find_message("shop.Item")
    assert_equal [["_price_cents", true]], m.oneofs.map { |o| [o.name, o.synthetic?] }
    assert_equal [["StockEntry", true]], m.nested_messages.map { |n| [n.name, n.map_entry?] }
    assert m.field("stock").map?
    assert_equal "priceCents", m.field("price_cents").json_name

    expected = compiled("shop.proto", <<~PROTO)
      syntax = "proto3";
      package shop;
      message Item {
        string name = 1;
        optional int64 price_cents = 2;
        map<string, int32> stock = 3;
      }
    PROTO
    assert_same_descriptor expected, built
  end

  def test_proto2_groups_extensions_enums_services_and_defaults
    expected = compiled("two.proto", <<~PROTO)
      syntax = "proto2";
      package two;
      message Base { extensions 100 to 199; }
      message Holder {
        optional group Result = 1 { required string url = 2; }
        optional int32 count = 3 [default = -5];
        optional Kind kind = 4 [default = B];
        oneof pick {
          string a = 5;
          group Choice = 6 { optional int32 x = 7; }
        }
        map<string, Holder> children = 8;
        extend Base { optional string note = 100; }
        reserved 20 to 25, 30;
        reserved "old";
      }
      enum Kind { option allow_alias = true; A = 0; B = 1; ALSO_B = 1; }
      extend Base { repeated int64 marks = 101 [packed = true]; }
      service Search { rpc Find(Holder) returns (stream Base); }
    PROTO

    file = S::File.draft("two.proto", package: "two")
    file.message("Base") { |m| m.extensions 100..199 }
    file.message("Holder") do |m|
      m.group("Result", 1) { |g| g.field "url", 2, :string, label: :required }
      m.field "count", 3, :int32, default: -5
      m.field "kind", 4, "Kind", default: :B
      m.oneof "pick" do |o|
        o.field "a", 5, :string
        o.group("Choice", 6) { |g| g.field "x", 7, :int32 }
      end
      m.map "children", 8, key: :string, value: "Holder"
      m.extend("Base") { |e| e.field "note", 100, :string }
      m.reserved 20..25, 30, "old"
    end
    file.enum("Kind", options: {allow_alias: true}) do |e|
      e.value :A, 0
      e.value :B, 1
      e.value :ALSO_B, 1
    end
    file.extend("Base") { |e| e.field "marks", 101, :int64, label: :repeated, options: {packed: true} }
    file.service("Search") { |s| s.rpc "Find", "Holder", "Base", server_streaming: true }
    built = file.resolve(@pool).freeze!

    assert_same_descriptor expected, built
    holder = built.find_message("two.Holder")
    assert_equal :group, holder.field("result").type
    assert_equal :required, holder.nested_messages.first.field("url").label
    assert_equal(-5, holder.field("count").default)
    assert_equal :B, holder.field("kind").default
    assert built.extensions.first.packed?
  end

  def test_editions_features
    expected = compiled("ed.proto", <<~PROTO)
      edition = "2023";
      package ed;
      option features.field_presence = IMPLICIT;
      message Node {
        int32 id = 1 [features.field_presence = LEGACY_REQUIRED];
        Node child = 2 [features.message_encoding = DELIMITED];
        repeated int32 ids = 3;
      }
    PROTO
    file = S::File.draft("ed.proto", package: "ed", edition: :EDITION_2023,
      options: {features: {field_presence: :IMPLICIT}})
    file.message("Node") do |m|
      m.field "id", 1, :int32, options: {features: {field_presence: :LEGACY_REQUIRED}}
      m.field "child", 2, "Node", options: {features: {message_encoding: :DELIMITED}}
      m.field "ids", 3, :int32, label: :repeated
    end
    built = file.resolve(@pool).freeze!

    assert_same_descriptor expected, built
    node = built.find_message("ed.Node")
    assert_equal [:required, :group, :repeated], node.fields.map { |f| (f.type == :int32) ? f.label : f.type }
    assert node.field("ids").packed?
  end

  def test_synthetic_oneof_names_avoid_every_name_in_the_message
    file = S::File.draft("x.proto", syntax: :proto3)
    file.message("M") do |m|
      m.oneof("_foo") { |o| o.field "a", 1, :int32 }
      m.field "foo", 2, :int32, optional: true
      m.field "_bar", 3, :int32, optional: true
    end
    built = file.resolve(@pool).freeze!
    assert_equal %w[_foo X_foo X_bar], built.find_message("M").oneofs.map(&:name)
  end

  def test_lookups_work_once_linked_before_freezing
    file = S::File.draft("l.proto", package: "l")
    file.message("A") { |m| m.field "b", 1, "B" }
    file.message("B")
    file.link(@pool)
    a = file.descriptor.find_message("l.A")
    assert_same file.descriptor.find_message("l.B"), a.field("b").message_type
    refute file.descriptor.frozen?
  end

  def test_errors
    error = assert_raises(S::Error) do
      S::File.draft("d.proto").tap { |f| 2.times { f.message("M") } }.resolve(@pool)
    end
    assert_match(/"M" is defined twice/, error.message)
    assert_raises(S::ResolveError) do
      S::File.draft("u.proto").tap { |f| f.message("M") { |m| m.field "x", 1, "Nope" } }.resolve(@pool)
    end
    assert_raises(S::Error) { S::File.draft("m.proto", dependencies: ["missing.proto"]).resolve(@pool) }
    assert_raises(S::Error) { S::File.draft("f.proto").freeze! }
    assert_raises(S::Error) { S::File.draft("t.proto").message("M") { |m| m.field "x", 1, :int32, "T" } }
    assert_raises(S::Error) { S::File.draft("t.proto").message("M") { |m| m.field "x", 1, :int33 } }
    assert_raises(S::Error) { S::File.draft("t.proto").message("M") { |m| m.field "x", 1, :int32, label: :maybe } }
    assert_raises(S::Error) { S::File.draft("s.proto", syntax: :proto4) }
    assert_raises(S::Error) { S::File.draft("s.proto", syntax: :proto3, edition: :EDITION_2023) }
    assert_raises(S::Error) { S::File.draft("p.proto", public_dependencies: ["y.proto"]) }
  end

  def test_naming_rules
    assert_equal "StockEntry", S::Draft.map_entry_name("stock")
    assert_equal "FooBarEntry", S::Draft.map_entry_name("foo_bar")
    assert_equal "result", S::Draft.group_field_name("Result")
    assert_equal %w[X_a _b], S::Draft.synthetic_oneof_names(%w[a b], %w[a _a b])
    assert_equal "fooBar", S.json_name("foo_bar")
    assert_equal "FooBar", S.json_name("_foo_bar")
    assert_equal "foo", S.json_name("foo_")
  end
end
