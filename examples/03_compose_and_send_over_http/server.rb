# frozen_string_literal: true

require "bundler/setup"
require "socket"
require_relative "checkout_pb"

$stdout.sync = true
trap("INT") { exit }
port = Integer(ENV.fetch("PORT", "9292"))
server = TCPServer.new("127.0.0.1", port)
puts "Listening on http://127.0.0.1:#{port}"

1001.step do |order_number|
  connection = server.accept
  request_line = connection.gets
  headers = {}
  while (line = connection.gets) != "\r\n"
    name, value = line.split(":", 2)
    headers[name.downcase] = value.strip
  end
  body = connection.read(Integer(headers.fetch("content-length")))

  order = Checkout::PlaceOrder.decode(body)
  puts "#{request_line.chomp}: #{order.items.size} items for #{order.customer_email}"
  total = order.items.sum { |item| item.quantity * item.unit_price_cents }
  reply = Checkout::OrderPlaced.new(order_id: "A-#{order_number}", total_cents: total).encode

  connection.write("HTTP/1.1 201 Created\r\n",
    "Content-Type: application/x-protobuf\r\n",
    "Content-Length: #{reply.bytesize}\r\n",
    "Connection: close\r\n\r\n", reply)
  connection.close
end
