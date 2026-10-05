# frozen_string_literal: true

require "bundler/setup"
require_relative "orders_pb"

order = Shop::Order.new(
  id: "A-1001",
  customer_email: "ada@example.com",
  status: :STATUS_PLACED,
  items: [Shop::LineItem.new(sku: "MUG-01", quantity: 2, unit_price_cents: 1250)]
)

puts order.inspect
puts order.items.first.unit_price_cents
puts order.encode.bytesize
