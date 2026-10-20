# frozen_string_literal: true

# The messages the benchmarks measure, for protostar and, when the process
# measures it, for google-protobuf. Classes come from the corpus goldens, so
# both sides read the same descriptors.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "protostar"
%w[corpus schema_fixtures codec_fixtures].each { |f| require_relative "../test/support/#{f}" }

module BenchFixtures
  SMALL_PROTO = <<~PROTO
    syntax = "proto3";
    package bench;
    message Small {
      enum Kind { KIND_UNSPECIFIED = 0; KIND_A = 1; KIND_B = 2; }
      message Inner { int32 a = 1; }
      int32 id = 1;
      int64 count = 2;
      string name = 3;
      bool active = 4;
      double score = 5;
      Inner inner = 6;
      Kind kind = 7;
      repeated int32 values = 8;
    }
  PROTO

  # The pbbuilder template of llm/outputs/ws9-report.md without Rails: a
  # person with 1,000 friends, each with two names, two tags, a flag, an
  # asset with three URLs and a two-entry map
  PEOPLE_PROTO = <<~PROTO
    syntax = "proto3";
    package bench;
    message Asset {
      string url = 1;
      string thumb_url = 2;
      string retina_url = 3;
    }
    message Person {
      string name = 1;
      string last_name = 2;
      repeated string tags = 3;
      bool active = 4;
      Asset logo = 5;
      map<string, string> attrs = 6;
      repeated Person friends = 7;
    }
  PROTO

  Racer = ::Struct.new(:name, :last_name, :tags, :active, :url, :attrs)

  module_function

  def test_all_types
    CodecFixtures.load("google/protobuf/unittest.proto")["proto2_unittest.TestAllTypes"]
  end

  # Every singular scalar field of TestAllTypes, and two elements in every repeated one
  def scalar_fields
    sample = {
      int32: [101, 201, 301], int64: [102, 202, 302], uint32: [103, 203, 303], uint64: [104, 204, 304],
      sint32: [105, 205, 305], sint64: [106, 206, 306], fixed32: [107, 207, 307], fixed64: [108, 208, 308],
      sfixed32: [109, 209, 309], sfixed64: [110, 210, 310], float: [111.0, 211.0, 311.0],
      double: [112.0, 212.0, 312.0], bool: [true, true, false], string: %w[115 215 315], bytes: %w[116 216 316]
    }
    fields = {}
    sample.each do |type, (one, two, three)|
      fields[:"optional_#{type}"] = one
      fields[:"repeated_#{type}"] = [two, three]
    end
    fields
  end

  def all_fields
    scalar_fields.merge(
      optionalgroup: {a: 117}, repeatedgroup: [{a: 217}, {a: 317}],
      optional_nested_message: {bb: 118}, optional_foreign_message: {c: 119},
      optional_import_message: {d: 120}, optional_public_import_message: {e: 126},
      optional_lazy_message: {bb: 127}, optional_unverified_lazy_message: {bb: 128},
      repeated_nested_message: [{bb: 218}, {bb: 318}], repeated_foreign_message: [{c: 219}, {c: 319}],
      repeated_import_message: [{d: 220}, {d: 320}], repeated_lazy_message: [{bb: 227}, {bb: 327}],
      optional_nested_enum: :BAZ, optional_foreign_enum: :FOREIGN_BAZ, optional_import_enum: :IMPORT_BAZ,
      repeated_nested_enum: %i[BAR BAZ], repeated_foreign_enum: %i[FOREIGN_BAR FOREIGN_BAZ],
      repeated_import_enum: %i[IMPORT_BAR IMPORT_BAZ],
      optional_string_piece: "124", optional_cord: "125", repeated_string_piece: %w[224 324],
      repeated_cord: %w[225 325], oneof_bytes: "604"
    )
  end

  def library_file
    @library_file ||= compiled("bench/library.proto", File.read(File.join(__dir__, "library.proto")))
  end

  def library
    @library ||= Protostar::Types::Registry.new.define(library_file).fetch("bench.library.Library")
  end

  # Eleven catalogues of about 440 KB: twenty elements in every repeated
  # field, a book in about half the slots
  def libraries
    random = Random.new(2026)
    Array.new(11) { fake(library, random) }
  end

  def fake(klass, random)
    fields = {}
    klass.reflection.fields.each do |f|
      if f.repeated?
        fields[f.name.to_sym] = Array.new(20) { fake_value(klass, f, random) }
      elsif !f.proto3_optional? || random.rand < 0.5
        fields[f.name.to_sym] = fake_value(klass, f, random)
      end
    end
    klass.new(fields)
  end

  def fake_value(klass, field, random)
    case field.type
    when :bool then random.rand < 0.5
    when :string then "Lorem ipsum ‡" + " dolor" * random.rand(0..6)
    when :enum then field.enum_type.values.sample(random: random).name.to_sym
    when :double, :float then random.rand * 1000.0
    when :message then fake(klass.reflection.message_class(field), random)
    else random.rand(0..400)
    end
  end

  def google_library
    google_file(library_file).lookup("bench.library.Library").msgclass
  end

  def compiled(name, source)
    Protostar::Compiler.new.compile([name], sources: {name => source}).last
  end

  def small_file
    @small_file ||= compiled("bench/small.proto", SMALL_PROTO)
  end

  def small
    @small ||= Protostar::Types::Registry.new.define(small_file).fetch("bench.Small")
  end

  def small_fields
    {id: 1, count: 2, name: "hello", active: true, score: 1.5, inner: {a: 1}, kind: :KIND_B, values: (1..20).to_a}
  end

  def people_file
    @people_file ||= compiled("bench/people.proto", PEOPLE_PROTO)
  end

  def people
    @people ||= Protostar::Types::Registry.new.define(people_file)
  end

  def racers(count = 1000)
    Array.new(count) do |i|
      Racer.new("Racer #{i}", "Lastname #{i}", ["fast", "team #{i % 7}"], i.even?,
        "https://cdn.example.com/logos/#{i}.png", {"country" => "NL", "number" => i.to_s})
    end
  end

  def person_hash(racer)
    {name: racer.name, last_name: racer.last_name, tags: racer.tags, active: racer.active,
     logo: {url: racer.url, thumb_url: "#{racer.url}?w=64", retina_url: "#{racer.url}?w=512"}, attrs: racer.attrs}
  end

  # google-protobuf, only in the process that measures it
  def google_pool(relative)
    require "google/protobuf"
    require "google/protobuf/descriptor_pb"
    pool = Google::Protobuf::DescriptorPool.new
    files = Google::Protobuf::FileDescriptorSet.decode(File.binread(Corpus.golden(relative, :binpb))).file
    files.each do |file|
      file.clear_source_code_info
      pool.add_serialized_file(Google::Protobuf::FileDescriptorProto.encode(file))
    end
    define_google_classes(pool, files)
  end

  # A message class of a pool that is not the generated pool can only make
  # nested messages whose classes were looked up, as generated code does
  def define_google_classes(pool, files)
    walk = lambda do |prefix, message|
      name = "#{prefix}#{message.name}"
      pool.lookup(name).msgclass unless message.options&.map_entry
      message.nested_type.each { |n| walk.call("#{name}.", n) }
    end
    files.each { |f| f.message_type.each { |m| walk.call(f.package.empty? ? "" : "#{f.package}.", m) } }
    pool
  end

  def google_class(full_name, relative = "google/protobuf/unittest.proto")
    (@google_pools ||= {})[relative] ||= google_pool(relative)
    @google_pools[relative].lookup(full_name).msgclass
  end

  def google_file(file)
    require "google/protobuf"
    require "google/protobuf/descriptor_pb"
    bytes = file.serialize(source_info: false)
    pool = Google::Protobuf::DescriptorPool.new
    pool.add_serialized_file(bytes)
    define_google_classes(pool, [Google::Protobuf::FileDescriptorProto.decode(bytes)])
  end

  def google_small
    google_file(small_file).lookup("bench.Small").msgclass
  end

  def google_people
    google_file(people_file)
  end
end
