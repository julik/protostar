# frozen_string_literal: true

require "bundler/setup"
require_relative "orders_pb"

bytes = File.binread("order.binpb")
order = Shop::Order.decode(bytes)

puts order.id
puts order.status.inspect
puts order.customer.address.city
puts order.items.map(&:sku).join(", ")
puts order.labels["channel"]

puts order.has_customer?
puts order.has_coupon_code?
puts order.coupon_code.inspect

order.unknown_fields.each do |field|
  puts "unknown field #{field.number}: #{field.value.inspect}"
end

puts order.inspect

File.open("orders.binpb", "rb") do |file|
  while (shipped = Shop::Order.decode_delimited(file))
    puts "#{shipped.id}: #{shipped.items.first.quantity} mug(s)"
  end
end
