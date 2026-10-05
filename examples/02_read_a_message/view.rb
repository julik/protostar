# frozen_string_literal: true

require "bundler/setup"
require_relative "orders_pb"

items = Array.new(100_000) { |i| {sku: "SKU-#{i}", quantity: 1, unit_price_cents: 499} }
bytes = Shop::Order.new(id: "B-2002", status: :STATUS_SHIPPED, items: items).encode
puts "#{bytes.bytesize} bytes, #{items.size} line items"

def best_of_five
  Array.new(5) {
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t
  }.min * 1000
end

decode_ms = best_of_five do
  order = Shop::Order.decode(bytes)
  [order.id, order.status]
end
view_ms = best_of_five do
  order = Shop::Order.view(bytes)
  [order.id, order.status]
end

order = Shop::Order.view(bytes)
puts "#{order.id} #{order.status.inspect}"
puts format("decode: %.1f ms", decode_ms)
puts format("view:   %.1f ms", view_ms)
