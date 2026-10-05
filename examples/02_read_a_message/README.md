# Read a message from the wire

Protobuf bytes reach you as a String: read from a file, a socket, an HTTP body.
This playbook turns them back into an object and reads everything a message can hold.

## Set up

```ruby
# examples/02_read_a_message/Gemfile
# frozen_string_literal: true

source "https://rubygems.org"

gem "protostar", path: "../.."
```

```console
$ bundle install
```

## The schema

An order with a nested customer, repeated line items, a map, an enum and one
`optional` field.

```proto
// examples/02_read_a_message/orders.proto
syntax = "proto3";

package shop;

message Order {
  string id = 1;
  Customer customer = 2;
  repeated LineItem items = 3;
  Status status = 4;
  // Free-form labels, like "channel" => "web".
  map<string, string> labels = 5;
  optional string coupon_code = 6;
}

message Customer {
  string email = 1;
  string full_name = 2;
  Address address = 3;
}

message Address {
  string street = 1;
  string city = 2;
  string country_code = 3;
}

message LineItem {
  string sku = 1;
  uint32 quantity = 2;
  int64 unit_price_cents = 3;
}

enum Status {
  STATUS_UNSPECIFIED = 0;
  STATUS_PLACED = 1;
  STATUS_SHIPPED = 2;
}
```

```console
$ bundle exec protostar compile -I . --ruby_out=. orders.proto
```

## Where the bytes come from

`order.binpb` holds one order and `orders.binpb` holds three. Another service wrote
them with a newer copy of the schema, one that has a field yours does not:

```proto
// examples/02_read_a_message/sender/orders.proto
syntax = "proto3";

package shop;

message Order {
  string id = 1;
  Customer customer = 2;
  repeated LineItem items = 3;
  Status status = 4;
  // Free-form labels, like "channel" => "web".
  map<string, string> labels = 5;
  optional string coupon_code = 6;
  // Added after the reader in ../orders.proto was compiled.
  string gift_note = 7;
}

message Customer {
  string email = 1;
  string full_name = 2;
  Address address = 3;
}

message Address {
  string street = 1;
  string city = 2;
  string country_code = 3;
}

message LineItem {
  string sku = 1;
  uint32 quantity = 2;
  int64 unit_price_cents = 3;
}

enum Status {
  STATUS_UNSPECIFIED = 0;
  STATUS_PLACED = 1;
  STATUS_SHIPPED = 2;
}
```

This is how it wrote them. The second file is a stream: each message is prefixed
with its length, so many fit in one file.

```ruby
# examples/02_read_a_message/sender/write.rb
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
```

## Decode

Load the generated code.

```ruby
# examples/02_read_a_message/run.rb
# frozen_string_literal: true

require "bundler/setup"
require_relative "orders_pb"
```

Read the bytes in binary mode and decode them. Nothing else is needed.

```ruby
# examples/02_read_a_message/run.rb
bytes = File.binread("order.binpb")
order = Shop::Order.decode(bytes)
```

## Read fields

Scalars are Ruby values, nested messages are objects, repeated fields are Arrays,
maps are Hashes and enum values are Symbols.

```ruby
# examples/02_read_a_message/run.rb
puts order.id
puts order.customer.address.city
puts order.items.map(&:sku).join(", ")
puts order.labels["channel"]
puts order.status.inspect
```

## Check presence

A message field and an `optional` field know whether they were sent. Asking for an
unset one gives its default, so ask `has_...?` when the difference matters.

```ruby
# examples/02_read_a_message/run.rb
puts order.has_customer?
puts order.has_coupon_code?
puts order.coupon_code.inspect
```

Plain proto3 scalars like `id` have no `has_id?`: an empty string and no string
look the same on the wire.

## Keep what you do not know

`gift_note` is not in your schema. The decoder keeps it as an unknown field, and
encoding the message again writes it back. A service in the middle can pass newer
messages through without losing anything.

```ruby
# examples/02_read_a_message/run.rb
order.unknown_fields.each do |field|
  puts "unknown field #{field.number}: #{field.value.inspect}"
end
puts order.encode == bytes
```

## Look at the whole thing

`inspect` shows every field that is set. `to_h` gives plain Hashes and Arrays.

```ruby
# examples/02_read_a_message/run.rb
puts order.inspect
puts order.to_h[:customer][:address].inspect
```

## Read a stream

`decode_delimited` reads one length-prefixed message from an IO and returns nil at
the end.

```ruby
# examples/02_read_a_message/run.rb
File.open("orders.binpb", "rb") do |file|
  while (shipped = Shop::Order.decode_delimited(file))
    puts "#{shipped.id}: #{shipped.items.first.quantity} mug(s)"
  end
end
```

## Run it

```console
$ ruby run.rb
A-1001
London
MUG-01, TEA-07
web
:STATUS_PLACED
true
false
""
unknown field 7: "Happy birthday!"
true
#<shop.Order id: "A-1001", customer: #<shop.Customer email: "ada@example.com", full_name: "Ada Lovelace", address: #<shop.Address street: "12 St James's Square", city: "London", country_code: "GB">>, items: [#<shop.LineItem sku: "MUG-01", quantity: 2, unit_price_cents: 1250>, #<shop.LineItem sku: "TEA-07", quantity: 1, unit_price_cents: 899>], status: :STATUS_PLACED, labels: {"channel" => "web", "campaign" => "autumn"}>
{street: "12 St James's Square", city: "London", country_code: "GB"}
A-1001: 1 mug(s)
A-1002: 2 mug(s)
A-1003: 3 mug(s)
```

On Ruby before 3.4 the Hashes print in the old `{"channel"=>"web"}` style.

## Read two fields out of a huge message

`decode` builds every object in the message. When the message is large and you
need two fields of it, use `Shop::Order.view(bytes)` instead: it answers the same
readers, finds where each field sits without decoding it, and decodes only what
you read. A view is read-only; call `to_message` on it when you want the real thing.
This script times both on an order with 100,000 line items.

```ruby
# examples/02_read_a_message/view.rb
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
```

```console
$ ruby view.rb
1788900 bytes, 100000 line items
B-2002 :STATUS_SHIPPED
decode: 132.6 ms
view:   17.0 ms
```

Your numbers will differ; the gap should not. Protobuf has no index of where fields
sit, so the view still walks past every line item. That walk is all the time it takes.
