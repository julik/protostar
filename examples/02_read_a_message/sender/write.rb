# frozen_string_literal: true

require "bundler/setup"
require_relative "orders_pb"

order = Shop::Order.new(
  id: "A-1001",
  customer: {
    email: "ada@example.com",
    full_name: "Ada Lovelace",
    address: {street: "12 St James's Square", city: "London", country_code: "GB"}
  },
  items: [
    {sku: "MUG-01", quantity: 2, unit_price_cents: 1250},
    {sku: "TEA-07", quantity: 1, unit_price_cents: 899}
  ],
  status: :STATUS_PLACED,
  labels: {"channel" => "web", "campaign" => "autumn"},
  gift_note: "Happy birthday!"
)
File.binwrite(File.join(__dir__, "..", "order.binpb"), order.encode)

File.open(File.join(__dir__, "..", "orders.binpb"), "wb") do |file|
  %w[A-1001 A-1002 A-1003].each_with_index do |id, i|
    Shop::Order.new(id: id, status: :STATUS_SHIPPED, items: [{sku: "MUG-01", quantity: i + 1}]).encode_delimited(file)
  end
end
