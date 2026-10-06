# frozen_string_literal: true

require "test_helper"

# Protostar::DSL as a hand-written API: each block builds exactly what the
# compiler builds from the equivalent .proto
class DslTest < Minitest::Test
  DSL = Protostar::DSL

  def setup
    @pool = Protostar::Schema::Pool.new
    @registry = Protostar::Types::Registry.new
    @compiler = Protostar::Compiler.new
  end

  def compiled(name, source)
    @compiler.compile([name], sources: {name => source}).each do |f|
      next if @pool.include?(f.name) || f.name == name
      @pool.add(Protostar::Schema::File.from_proto(f.serialize(source_info: false), pool: @pool))
    end.last
  end

  def dsl(name, **kwargs, &block)
    DSL.file(name, pool: @pool, registry: @registry, **kwargs, &block)
  end

  def test_proto3_with_maps_oneofs_custom_options_and_services
    expected = compiled("dsltest/three.proto", <<~PROTO)
      syntax = "proto3";
      package dsltest.three;
      import "google/protobuf/descriptor.proto";
      option java_package = "com.acme";
      extend google.protobuf.FieldOptions { string tag = 51001; }
      extend google.protobuf.MessageOptions { repeated int32 marks = 51002; }
      message Person {
        option (marks) = 1;
        option (marks) = 2;
        string name = 1 [(tag) = "n"];
        int32 id = 2 [json_name = "personId"];
        repeated Person friends = 3;
        oneof contact {
          string email = 5;
          string phone = 6;
        }
        map<string, Person> by_name = 7;
        map<int32, Kind> kinds = 8;
        optional int64 age = 9;
        enum Kind { UNKNOWN = 0; HUMAN = 1; }
        message Address { string street = 1; }
        reserved 100 to 199, 300;
        reserved "old_name";
      }
      service Greeter {
        option deprecated = true;
        rpc SayHello(Person) returns (Person);
        rpc Lots(stream Person) returns (stream Person) { option idempotency_level = NO_SIDE_EFFECTS; }
      }
    PROTO
    file = dsl("dsltest/three.proto", package: "dsltest.three", syntax: :proto3,
      dependencies: ["google/protobuf/descriptor.proto"], java_package: "com.acme") do |f|
      f.extend ".google.protobuf.FieldOptions" do |e|
        e.field :tag, 51001, :string
      end
      f.extend "google.protobuf.MessageOptions" do |e|
        e.field :marks, 51002, :int32, label: :repeated
      end
      f.message "Person", extensions: {"dsltest.three.marks" => [1, 2]} do |m|
        m.field :name, 1, :string, extensions: {"dsltest.three.tag" => "n"}
        m.field :id, 2, :int32, json_name: "personId"
        m.field :friends, 3, "Person", label: :repeated
        m.oneof :contact do |o|
          o.field :email, 5, :string
          o.field :phone, 6, :string
        end
        m.map :by_name, 7, :string, ".dsltest.three.Person"
        m.map :kinds, 8, :int32, :enum, "Kind"
        m.field :age, 9, :int64, proto3_optional: true
        m.enum "Kind" do |e|
          e.value :UNKNOWN, 0
          e.value :HUMAN, 1
        end
        m.message "Address" do |a|
          a.field :street, 1, :string
        end
        m.reserved 100..199, 300, "old_name"
      end
      f.service "Greeter", deprecated: true do |s|
        s.rpc :SayHello, ".dsltest.three.Person", ".dsltest.three.Person"
        s.rpc :Lots, "Person", "Person", client_streaming: true, server_streaming: true,
          idempotency_level: :NO_SIDE_EFFECTS
      end
    end
    assert_equal expected.to_h, file.to_h
    person = @registry.find("dsltest.three.Person")
    message = person.new(name: "Ada", by_name: {"x" => person.new(id: 2)}, age: 0)
    assert_equal message, person.decode(message.encode)
  end

  def test_proto2_with_groups_defaults_extensions_and_aliases
    expected = compiled("dsltest/two.proto", <<~'PROTO')
      syntax = "proto2";
      package dsltest.two;
      message Outer {
        required int32 a = 1 [default = 5];
        optional string s = 2 [default = "hi\n"];
        optional bytes b = 3 [default = "\001x"];
        optional Color c = 4 [default = GREEN];
        optional float f = 5 [default = 1.5];
        repeated int32 packed_ints = 6 [packed = true];
        optional group Data = 7 { optional int32 x = 1; }
        oneof choice {
          int32 n = 8;
          group Inner = 9 { optional int32 y = 1; }
        }
        extensions 100 to 199;
        extensions 1000 to max;
        extend Outer { optional int32 ext_in_message = 100; }
        enum Color { option allow_alias = true; RED = 0; GREEN = 1; VERDE = 1 [deprecated = true]; }
      }
      extend Outer {
        optional int32 file_ext = 101;
        repeated group Rep = 102 { optional int32 z = 1; }
      }
      message MSet {
        option message_set_wire_format = true;
        extensions 4 to max;
      }
    PROTO
    file = dsl("dsltest/two.proto", package: "dsltest.two", syntax: :proto2) do |f|
      f.message "Outer" do |m|
        m.field :a, 1, :int32, label: :required, default: 5
        m.field :s, 2, :string, default: "hi\n"
        m.field :b, 3, :bytes, default: "\\001x"
        m.field :c, 4, :enum, ".dsltest.two.Outer.Color", default: :GREEN
        m.field :f, 5, :float, default: 1.5
        m.field :packed_ints, 6, :int32, label: :repeated, packed: true
        m.group "Data", 7 do |g|
          g.field :x, 1, :int32
        end
        m.oneof :choice do |o|
          o.field :n, 8, :int32
          o.group "Inner", 9 do |g|
            g.field :y, 1, :int32
          end
        end
        m.extensions 100..199, 1000..536870911
        m.extend ".dsltest.two.Outer" do |e|
          e.field :ext_in_message, 100, :int32
        end
        m.enum "Color", allow_alias: true do |e|
          e.value :RED, 0
          e.value :GREEN, 1
          e.value :VERDE, 1, deprecated: true
        end
      end
      f.message "Rep" do |m|
        m.field :z, 1, :int32
      end
      f.extend ".dsltest.two.Outer" do |e|
        e.field :file_ext, 101, :int32
        e.field :rep, 102, :group, ".dsltest.two.Rep", label: :repeated
      end
      f.message "MSet", message_set_wire_format: true do |m|
        m.extensions 4...2147483647
      end
    end
    expected_hash = expected.to_h
    expected_hash.delete(:syntax)
    assert_equal expected_hash, file.to_h.tap { |h| h.delete(:syntax) }
    assert_equal "proto2", file.to_h[:syntax]
  end

  def test_editions_and_features
    expected = compiled("dsltest/ed.proto", <<~PROTO)
      edition = "2023";
      package dsltest.ed;
      option features.field_presence = IMPLICIT;
      message E {
        int32 a = 1 [features.field_presence = EXPLICIT];
        E child = 2 [features.message_encoding = DELIMITED];
      }
    PROTO
    file = dsl("dsltest/ed.proto", package: "dsltest.ed", edition: 2023, features: {field_presence: :IMPLICIT}) do |f|
      f.message "E" do |m|
        m.field :a, 1, :int32, features: {field_presence: :EXPLICIT}
        m.field :child, 2, :message, ".dsltest.ed.E", features: {message_encoding: :DELIMITED}
      end
    end
    assert_equal expected.to_h, file.to_h
    assert_equal :group, file.find_message("dsltest.ed.E").field("child").type
  end

  def test_loading_twice_is_a_no_op
    first = dsl("dsltest/once.proto", package: "dsltest.once") { |f| f.message("A") }
    second = dsl("dsltest/once.proto", package: "dsltest.once") { |f| flunk "block evaluated again: #{f}" }
    assert_same first, second
  end

  def test_lookups
    dsl("dsltest/look.proto", package: "dsltest.look", syntax: :proto3) do |f|
      f.message "M" do |m|
        m.enum "E" do |e|
          e.value :Z, 0
        end
      end
      f.service "S" do |s|
        s.rpc :Call, ".dsltest.look.M", ".dsltest.look.M"
      end
    end
    m = DSL.message("dsltest.look.M", registry: @registry)
    assert_equal "dsltest.look.M", m.descriptor.full_name
    assert_equal 0, DSL.enum("dsltest.look.M.E", registry: @registry)::Z
    service = DSL.service("dsltest.look.S", pool: @pool)
    assert_instance_of Module, service
    assert_equal "dsltest.look.S", service.descriptor.full_name
    refute service.frozen?, "gRPC stubs reopen the module"
    assert_raises(DSL::Error) { DSL.message("dsltest.look.M.E", registry: @registry) }
    assert_raises(DSL::Error) { DSL.enum("dsltest.look.M", registry: @registry) }
    assert_raises(DSL::Error) { DSL.service("dsltest.look.Nope", pool: @pool) }
  end

  def test_verbatim_options_and_public_dependencies
    dsl("dsltest/base.proto", package: "dsltest.base") { |f| f.message("B") }
    file = dsl("dsltest/user.proto", package: "dsltest.user", dependencies: ["dsltest/base.proto"],
      public_dependencies: ["dsltest/base.proto"], options: {}) do |f|
      f.message "U", options: {} do |m|
        m.field :b, 1, ".dsltest.base.B"
        m.reserved 5
      end
    end
    h = file.to_h
    assert_equal [0], h[:public_dependency]
    assert_equal({}, h[:options])
    assert_equal({}, h[:message_type][0][:options])
    assert_equal [{start: 5, end: 6}], h[:message_type][0][:reserved_range]
    assert_equal :TYPE_MESSAGE, h[:message_type][0][:field][0][:type]
  end

  def test_bad_input
    assert_raises(DSL::Error) { dsl("x.proto") { |f| f.message("M") { |m| m.field :a, 1, :int33 } } }
    assert_raises(DSL::Error) { dsl("x.proto") { |f| f.message("M") { |m| m.field :a, 1, :int32, label: :maybe } } }
    assert_raises(DSL::Error) { dsl("x.proto", syntax: :proto4) }
    assert_raises(DSL::Error) { dsl("x.proto", public_dependencies: ["y.proto"]) }
    refute @pool.include?("x.proto")
    assert_raises(Protostar::Schema::Error) { dsl("dsltest/bad.proto") { |f| f.message("M") { |m| m.field :a, 1, ".Nope" } } }
  end

  OPTION_TYPES = <<~PROTO
    syntax = "proto2";
    package dsltest.spell;
    import "google/protobuf/descriptor.proto";
    message Note {
      optional string text = 1;
      optional string extensions = 2;
      extensions 100 to 199;
    }
    extend Note { optional int32 weight = 100; }
    extend google.protobuf.MessageOptions { optional Note note = 52001; }
  PROTO

  def spelled(name, visibility: :export, &message_block)
    @pool.add(compiled("dsltest/spell_types.proto", OPTION_TYPES)) unless @pool.include?("dsltest/spell_types.proto")
    dsl(name, package: "dsltest.spell.#{File.basename(name, ".proto")}", edition: 2024, dependencies: ["dsltest/spell_types.proto"]) do |f|
      f.message("M", visibility: visibility, **message_block.call)
    end.messages.first
  end

  def test_spelling_of_extensions_unknown_fields_and_visibility
    unknown = "\xA0\x1F\x05".b # field 500, varint 5
    message = spelled("dsltest/spell_new.proto") do
      {extensions: {"dsltest.spell.note" => {
        :text => "t", "extensions" => "a field", :extensions => {"dsltest.spell.weight" => 3},
        :unknown_fields => unknown
      }}}
    end
    note = message.options.extension("dsltest.spell.note")
    assert_equal "t", note[:text]
    assert_equal "a field", note[:extensions]
    assert_equal 3, note.extension("dsltest.spell.weight")
    assert_equal unknown, note.unknown_fields
    assert_equal :export, message.visibility

    source = Protostar::Compiler::Emitters::Ruby.new.definition(message.file)
    assert_includes source, "  f.message \"M\",\n    visibility: :export,\n"
    assert_includes source, '"extensions" => "a field"'
    assert_includes source, 'extensions: {"dsltest.spell.weight" => 3}'
    assert_includes source, 'unknown_fields: "\xA0\x1F\x05".b'
    refute_includes source, "__"
  end

  def test_old_spellings_are_read_with_a_deprecation_warning
    expected = spelled("dsltest/spell_now.proto") do
      {extensions: {"dsltest.spell.note" => {text: "t", extensions: {"dsltest.spell.weight" => 3},
                                             unknown_fields: "\xA0\x1F\x05".b}}}
    end
    old = nil
    deprecated, Warning[:deprecated] = Warning[:deprecated], true
    _, err = capture_io do
      old = spelled("dsltest/spell_old.proto", visibility: :VISIBILITY_EXPORT) do
        {extensions: {"dsltest.spell.note" => {text: "t", __extensions: {"dsltest.spell.weight" => 3},
                                               __unknown_fields: [[500, 0, "\x05".b]]}}}
      end
    end
    Warning[:deprecated] = deprecated
    assert_equal expected.options.extension("dsltest.spell.note"), old.options.extension("dsltest.spell.note")
    assert_equal :export, old.visibility
    lines = err.lines
    assert_equal 3, lines.size, err
    assert lines.all? { |l| l.start_with?("#{__FILE__}:") }, err
    assert_match(/visibility: :VISIBILITY_EXPORT is deprecated .* write visibility: :export/, lines[0])
    assert_match(/__extensions: is deprecated .* write extensions:/, err)
    assert_match(/__unknown_fields: .* is deprecated .* write unknown_fields:/, err)
  end

  def test_map_entry_name
    assert_equal "FooBarEntry", DSL.map_entry_name("foo_bar")
    assert_equal "X1yEntry", DSL.map_entry_name("x1y")
    assert_equal "FooEntry", DSL.map_entry_name("_foo")
  end
end
