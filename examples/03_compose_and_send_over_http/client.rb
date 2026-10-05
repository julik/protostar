# frozen_string_literal: true

require "bundler/setup"
require "net/http"
require_relative "checkout_pb"

order = Checkout::PlaceOrder.new(
  customer_email: "ada@example.com",
  items: [Checkout::LineItem.new(sku: "MUG-01", quantity: 2, unit_price_cents: 1250)]
)

order.items << Checkout::LineItem.new(sku: "TEA-07", quantity: 1, unit_price_cents: 899)
order.coupon_code = "AUTUMN"

body = order.encode
puts "Sending #{body.bytesize} bytes"

uri = URI("http://127.0.0.1:#{ENV.fetch("PORT", "9292")}/orders")
response = Net::HTTP.post(uri, body, "Content-Type" => "application/x-protobuf")
puts "#{response.code} #{response["Content-Type"]}"

placed = Checkout::OrderPlaced.decode(response.body)
puts "Order #{placed.order_id}, total #{placed.total_cents} cents"
