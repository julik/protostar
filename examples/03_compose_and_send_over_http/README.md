# Compose a message and send it over HTTP

Build a message, turn it into bytes, POST them. On the other side, a small server
decodes the body and answers with a message of its own.

## Set up

```ruby
# examples/03_compose_and_send_over_http/Gemfile
# frozen_string_literal: true

source "https://rubygems.org"

gem "protostar", path: "../.."
```

```console
$ bundle install
```

## The schema

One message goes to the server, another comes back.

```proto
// examples/03_compose_and_send_over_http/checkout.proto
syntax = "proto3";

package checkout;

// What the shop front sends when a customer pays.
message PlaceOrder {
  string customer_email = 1;
  repeated LineItem items = 2;
  string coupon_code = 3;
}

message LineItem {
  string sku = 1;
  uint32 quantity = 2;
  int64 unit_price_cents = 3;
}

// What the checkout service answers.
message OrderPlaced {
  string order_id = 1;
  int64 total_cents = 2;
}
```

```console
$ bundle exec protostar compile -I . --ruby_out=. checkout.proto
```

## The client

Load the generated code and `net/http`.

```ruby
# examples/03_compose_and_send_over_http/client.rb
# frozen_string_literal: true

require "bundler/setup"
require "net/http"
require_relative "checkout_pb"
```

Build the message with keyword arguments.

```ruby
# examples/03_compose_and_send_over_http/client.rb
order = Checkout::PlaceOrder.new(
  customer_email: "ada@example.com",
  items: [Checkout::LineItem.new(sku: "MUG-01", quantity: 2, unit_price_cents: 1250)]
)
```

Or change it after the fact. A repeated field is an Array, so push into it.

```ruby
# examples/03_compose_and_send_over_http/client.rb
order.items << Checkout::LineItem.new(sku: "TEA-07", quantity: 1, unit_price_cents: 899)
order.coupon_code = "AUTUMN"
```

Turn it into bytes. The result is a binary String.

```ruby
# examples/03_compose_and_send_over_http/client.rb
body = order.encode
puts "Sending #{body.bytesize} bytes"
```

POST it. `application/x-protobuf` is the content type people use for protobuf
bodies. Nothing enforces it, and the server below does not even look.

```ruby
# examples/03_compose_and_send_over_http/client.rb
uri = URI("http://127.0.0.1:#{ENV.fetch("PORT", "9292")}/orders")
response = Net::HTTP.post(uri, body, "Content-Type" => "application/x-protobuf")
puts "#{response.code} #{response["Content-Type"]}"
```

The reply body is protobuf too. Decode it with the class you expect back.

```ruby
# examples/03_compose_and_send_over_http/client.rb
placed = Checkout::OrderPlaced.decode(response.body)
puts "Order #{placed.order_id}, total #{placed.total_cents} cents"
```

## The server

Thirty lines of `socket`, so that nothing hides what happens to the bytes. In an
app this is a Rack or Rails action, and the body is `request.body.read`.

```ruby
# examples/03_compose_and_send_over_http/server.rb
# frozen_string_literal: true

require "bundler/setup"
require "socket"
require_relative "checkout_pb"
```

Listen on port 9292, or on `PORT`.

```ruby
# examples/03_compose_and_send_over_http/server.rb
$stdout.sync = true
trap("INT") { exit }
port = Integer(ENV.fetch("PORT", "9292"))
server = TCPServer.new("127.0.0.1", port)
puts "Listening on http://127.0.0.1:#{port}"
```

For every request: read the headers, read exactly `Content-Length` bytes of body,
decode them, add up the order and answer with an encoded `OrderPlaced`.

```ruby
# examples/03_compose_and_send_over_http/server.rb
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
```

## Run both

Start the server in one terminal.

```console
$ ruby server.rb
Listening on http://127.0.0.1:9292
POST /orders HTTP/1.1: 2 items for ada@example.com
```

The second line appears when the client calls. Run the client in another terminal.

```console
$ ruby client.rb
Sending 55 bytes
201 application/x-protobuf
Order A-1001, total 3399 cents
```

Ctrl-C stops the server.
