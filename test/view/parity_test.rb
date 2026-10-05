# frozen_string_literal: true

require "test_helper"

# For every message of every corpus golden's own file: random messages with
# unknown fields read through a view exactly as the eager decoder reads them.
class ViewParityTest < Minitest::Test
  INSTANCES = Integer(ENV.fetch("PROTOSTAR_PROPERTY_INSTANCES", "4"))

  CodecFixtures.goldens.each do |relative|
    define_method(:"test_views_read_like_decode_#{relative.tr("/.", "__")}") do
      set = CodecFixtures.load(relative)
      random = Random.new(relative.sum + 8)
      checked = 0
      set.file.all_messages.each do |descriptor|
        next if descriptor.map_entry?
        klass = set[descriptor.full_name]
        INSTANCES.times do |n|
          message = RandomMessage.build(klass, random: random, depth: 3, fill: (n == 0) ? 1.0 : 0.5)
          assert_parity(klass, message.encode)
          checked += 1
        end
      end
      pass if checked.zero?
    end
  end

  # Readers by name, not only through to_h
  def test_readers_agree_field_by_field
    set = CodecFixtures.load("google/protobuf/unittest.proto")
    klass = set["proto2_unittest.TestAllTypes"]
    random = Random.new(42)
    8.times do
      bytes = RandomMessage.build(klass, random: random, depth: 2, fill: 0.7).encode
      message = klass.decode(bytes)
      view = klass.view(bytes)
      klass.__fields.each do |info|
        mine = view[info.name]
        theirs = message.__get(info)
        if info.message? && !info.repeated
          assert_equal theirs.nil?, mine.nil?, info.name
          assert_equal theirs, mine.to_message, info.name if theirs
        elsif info.message?
          assert_equal theirs, mine.map(&:to_message), info.name
        else
          assert_equal ViewSupport.plain(theirs), ViewSupport.plain(info.map ? mine.to_h : mine), info.name
        end
        assert_equal message.public_send(:"has_#{info.name}?"), view.public_send(:"has_#{info.name}?"), info.name if info.presence
      end
      assert_equal [message.which_oneof_field], [view.which_oneof_field]
    end
  end

  private

  def assert_parity(klass, bytes)
    name = klass.descriptor.full_name
    decoded = klass.decode(bytes)
    view = klass.view(bytes)
    assert_same bytes, view.encode, "encode is not the input for #{name}"
    assert_equal ViewSupport.plain(decoded.__to_h), ViewSupport.plain(view.to_h), "to_h differs for #{name}"
    assert_equal decoded, view.to_message, "to_message differs for #{name}"
    assert_equal view, decoded, "view == message fails for #{name}"
    assert_equal decoded.unknown_fields, view.unknown_fields, "unknown fields differ for #{name}"
    assert_nested_unknown_fields(decoded, view)
    frozen = klass.view(bytes.dup.freeze).freeze_index
    assert_equal ViewSupport.plain(decoded.__to_h), ViewSupport.plain(frozen.to_h), "to_h of a frozen index differs for #{name}"
    assert Ractor.shareable?(frozen), "#{name} view is not shareable after freeze_index"
  end

  def assert_nested_unknown_fields(message, view)
    message.class.__fields.each do |info|
      next unless info.message? && !info.map
      if info.repeated
        theirs = message.__get(info)
        mine = view[info.name]
        theirs.each_with_index do |m, i|
          assert_equal m.unknown_fields, mine[i].unknown_fields
          assert_nested_unknown_fields(m, mine[i])
        end
      elsif (m = message.__get(info))
        assert_equal m.unknown_fields, view[info.name].unknown_fields
        assert_nested_unknown_fields(m, view[info.name])
      end
    end
  end
end
