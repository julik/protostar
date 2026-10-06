# frozen_string_literal: true

# Views against eager decode: reading one scalar and one nested field, and a
# full to_h, on a large message (1 MiB: a 512 KiB bytes field, 512 strings of
# 1 KiB, 1000 nested messages) and on a populated TestAllTypes (314 bytes).
# google-protobuf has no views; its rows decode and read the same two fields.
#
#   ruby bench/view_bench.rb
#   BENCH_SIDE=google ruby bench/view_bench.rb

require_relative "bench"
require_relative "fixtures"

Bench.section "Views" do |s|
  klass = BenchFixtures.test_all_types
  large = klass.new(
    optional_int32: 1,
    optional_bytes: "y" * (512 * 1024),
    repeated_string: Array.new(512) { "x" * 1024 },
    optional_nested_message: {bb: 42},
    repeated_nested_message: Array.new(1000) { |i| {bb: i} },
    optional_foreign_message: {c: 9}
  ).encode.freeze
  small = klass.new(BenchFixtures.scalar_fields.merge(
    optionalgroup: {a: 117}, repeatedgroup: [{a: 217}, {a: 317}],
    optional_nested_message: {bb: 118}, optional_foreign_message: {c: 119},
    repeated_nested_message: [{bb: 218}, {bb: 318}], repeated_foreign_message: [{c: 219}, {c: 319}],
    optional_nested_enum: :BAZ, repeated_nested_enum: %i[BAR BAZ], oneof_bytes: "604"
  )).encode.freeze

  read_two = ->(m) { m.optional_int32 + m.optional_nested_message.bb }
  [large, small].each do |bytes|
    raise "views disagree" unless read_two.call(klass.view(bytes)) == read_two.call(klass.decode(bytes))
  end
  large_label = "large (#{large.bytesize / 1024} KiB)"
  small_label = "small (#{small.bytesize} bytes)"

  s.row("#{large_label}: view, read two fields") { read_two.call(klass.view(large)) }
  s.row("#{large_label}: decode, read two fields") { read_two.call(klass.decode(large)) }
  s.row("#{large_label}: view to_h") { klass.view(large).to_h }
  s.row("#{large_label}: decode to_h") { klass.decode(large).to_h }
  s.row("#{small_label}: view, read two fields") { read_two.call(klass.view(small)) }
  s.row("#{small_label}: decode, read two fields") { read_two.call(klass.decode(small)) }
  s.row("#{small_label}: view to_message") { klass.view(small).to_message }

  s.setup(side: :google) do
    g = BenchFixtures.google_class("proto2_unittest.TestAllTypes")
    s.row("#{large_label}: decode, read two fields", side: :google) { read_two.call(g.decode(large)) }
    s.row("#{large_label}: decode to_h", side: :google) { g.decode(large).to_h }
    s.row("#{small_label}: decode, read two fields", side: :google) { read_two.call(g.decode(small)) }
  end

  s.count("objects allocated: #{large_label}, view, read two fields") { Bench.allocations { read_two.call(klass.view(large)) } }
  s.count("objects allocated: #{large_label}, decode, read two fields") { Bench.allocations { read_two.call(klass.decode(large)) } }
end
