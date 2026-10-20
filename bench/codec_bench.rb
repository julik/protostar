# frozen_string_literal: true

# Decode and encode of a fully populated proto2_unittest.TestAllTypes, the
# shape of protobuf's TestUtil::SetAllFields: every singular field set and
# two elements in every repeated field (413 bytes). Then a small proto3
# message: six scalars, a nested message, an enum and twenty packed int32s
# (50 bytes). Then eleven library catalogues (bench/library.proto), about
# 440 KB each and nested four levels deep, 4.9 MB in all.
#
#   ruby bench/codec_bench.rb                     # protostar
#   BENCH_SIDE=google ruby bench/codec_bench.rb   # google-protobuf, where it is installed
#   ruby --yjit ...                               # with YJIT

require_relative "bench"
require_relative "fixtures"

Bench.section "Codec" do |s|
  klass = BenchFixtures.test_all_types
  message = klass.new(BenchFixtures.all_fields)
  bytes = message.encode
  raise "round trip failed" unless klass.decode(bytes) == message
  small_class = BenchFixtures.small
  small = small_class.new(BenchFixtures.small_fields)
  small_bytes = small.encode

  s.row("decode TestAllTypes, 413 bytes") { klass.decode(bytes) }
  s.row("decode TestAllTypes, frozen: true") { klass.decode(bytes, frozen: true) }
  s.row("encode TestAllTypes") { message.encode }
  s.row("decode small message, 50 bytes") { small_class.decode(small_bytes) }
  s.row("encode small message") { small.encode }

  s.setup(side: :google) do
    gklass = BenchFixtures.google_class("proto2_unittest.TestAllTypes")
    gmessage = gklass.decode(bytes)
    gsmall_class = BenchFixtures.google_small
    gsmall = gsmall_class.decode(small_bytes)
    s.row("decode TestAllTypes, 413 bytes", side: :google) { gklass.decode(bytes) }
    s.row("encode TestAllTypes", side: :google) { gklass.encode(gmessage) }
    s.row("decode small message, 50 bytes", side: :google) { gsmall_class.decode(small_bytes) }
    s.row("encode small message", side: :google) { gsmall_class.encode(gsmall) }
  end

  s.count("objects allocated by one TestAllTypes decode") { Bench.allocations { klass.decode(bytes) } }
  s.count("objects allocated by one TestAllTypes encode") { Bench.allocations { message.encode } }

  library = BenchFixtures.library
  catalogues = BenchFixtures.libraries
  catalogue_bytes = catalogues.map(&:encode)
  size = "%.1f MB" % (catalogue_bytes.sum(&:bytesize) / 1e6)
  s.row("decode 11 library catalogues, #{size}") { catalogue_bytes.each { |b| library.decode(b) } }
  s.row("decode 11 library catalogues, frozen: true") { catalogue_bytes.each { |b| library.decode(b, frozen: true) } }
  s.row("encode 11 library catalogues") { catalogues.each(&:encode) }

  s.setup(side: :google) do
    glibrary = BenchFixtures.google_library
    gcatalogues = catalogue_bytes.map { |b| glibrary.decode(b) }
    s.row("decode 11 library catalogues, #{size}", side: :google) { catalogue_bytes.each { |b| glibrary.decode(b) } }
    s.row("encode 11 library catalogues", side: :google) { gcatalogues.each { |m| glibrary.encode(m) } }
  end

  s.count("objects allocated by one library catalogue decode (#{catalogue_bytes[0].bytesize / 1000} KB)") do
    Bench.allocations { library.decode(catalogue_bytes[0]) }
  end
end
