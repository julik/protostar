# JSON for debugging and interop

Binary is for machines. When you want to see a message, or talk to something that
speaks JSON, protostar writes and reads the standard protobuf JSON mapping, and
the text format protoc prints.

## Set up

```ruby
# examples/04_json_for_debugging/Gemfile
# frozen_string_literal: true

source "https://rubygems.org"

gem "protostar", path: "../.."
```

```console
$ bundle install
```

## The schema

A customer with a 64-bit integer, some bytes and a timestamp, the three things JSON
cannot carry as is.

```proto
// examples/04_json_for_debugging/customer.proto
syntax = "proto3";

package crm;

import "google/protobuf/timestamp.proto";

message Customer {
  string id = 1;
  string full_name = 2;
  Tier tier = 3;
  // Can outgrow a JavaScript number, so JSON carries it as a string.
  int64 lifetime_spend_cents = 4;
  bytes avatar_digest = 5;
  repeated string tags = 6;
  google.protobuf.Timestamp signed_up_at = 7;
  uint32 open_tickets = 8;
}

enum Tier {
  TIER_UNSPECIFIED = 0;
  TIER_SILVER = 1;
  TIER_GOLD = 2;
}
```

`google/protobuf/timestamp.proto` ships with protostar, so the import just works.

```console
$ bundle exec protostar compile -I . --ruby_out=. customer.proto
```

## A customer

```ruby
# examples/04_json_for_debugging/run.rb
# frozen_string_literal: true

require "bundler/setup"
require "json"
require_relative "customer_pb"
```

A Timestamp field takes a Ruby `Time` and builds the Timestamp from it. The class
itself is `Protostar::Timestamp` (`Protostar::Timestamp.from_time(t)` does the same).

```ruby
# examples/04_json_for_debugging/run.rb
customer = Crm::Customer.new(
  id: "C-42",
  full_name: "Ada Lovelace",
  tier: :TIER_GOLD,
  lifetime_spend_cents: 9_007_199_254_740_993,
  avatar_digest: "\x9f\x86\xd0\x81".b,
  tags: ["early-adopter", "tea"],
  signed_up_at: Time.utc(2024, 3, 1, 9, 30)
)
```

## To JSON

```ruby
# examples/04_json_for_debugging/run.rb
puts customer.to_json
```

The output is compact. For your eyes, hand the message to the json gem's pretty printer.

```ruby
# examples/04_json_for_debugging/run.rb
puts JSON.pretty_generate(customer)
```

Two options matter. `emit_defaults: true` writes fields that hold their default
(`open_tickets` is 0, so it is normally left out). `preserve_proto_field_names: true`
keeps `full_name` instead of `fullName`.

```ruby
# examples/04_json_for_debugging/run.rb
puts customer.to_json(emit_defaults: true, preserve_proto_field_names: true)
```

## From JSON

`decode_json` reads what a JSON API sends. Both spellings of field names are accepted.

```ruby
# examples/04_json_for_debugging/run.rb
payload = <<~JSON
  {"id": "C-43", "fullName": "Grace Hopper", "tier": "TIER_SILVER",
   "lifetimeSpendCents": "1200", "signedUpAt": "2024-05-02T10:00:00Z"}
JSON
grace = Crm::Customer.decode_json(payload)
puts grace.inspect
puts grace.signed_up_at.to_time.utc
```

A field your schema does not have is an error, unless you say to skip it. Unlike
the binary decoder, JSON keeps nothing it does not know.

```ruby
# examples/04_json_for_debugging/run.rb
newer = '{"id": "C-44", "favouriteColour": "teal"}'
begin
  Crm::Customer.decode_json(newer)
rescue Protostar::JSON::ParseError => e
  puts e.message
end
puts Crm::Customer.decode_json(newer, ignore_unknown_fields: true).inspect
```

## The text format

`to_text` prints what `protoc --decode` would print. It is the format to paste into
a bug report.

```ruby
# examples/04_json_for_debugging/run.rb
puts customer.to_text
```

## Run it

```console
$ ruby run.rb
{"id":"C-42","fullName":"Ada Lovelace","tier":"TIER_GOLD","lifetimeSpendCents":"9007199254740993","avatarDigest":"n4bQgQ==","tags":["early-adopter","tea"],"signedUpAt":"2024-03-01T09:30:00Z"}
{
  "id": "C-42",
  "fullName": "Ada Lovelace",
  "tier": "TIER_GOLD",
  "lifetimeSpendCents": "9007199254740993",
  "avatarDigest": "n4bQgQ==",
  "tags": [
    "early-adopter",
    "tea"
  ],
  "signedUpAt": "2024-03-01T09:30:00Z"
}
{"id":"C-42","full_name":"Ada Lovelace","tier":"TIER_GOLD","lifetime_spend_cents":"9007199254740993","avatar_digest":"n4bQgQ==","tags":["early-adopter","tea"],"signed_up_at":"2024-03-01T09:30:00Z","open_tickets":0}
#<crm.Customer id: "C-43", full_name: "Grace Hopper", tier: :TIER_SILVER, lifetime_spend_cents: 1200, signed_up_at: #<google.protobuf.Timestamp seconds: 1714644000>>
2024-05-02 10:00:00 UTC
crm.Customer has no field "favouriteColour"
#<crm.Customer id: "C-44">
id: "C-42"
full_name: "Ada Lovelace"
tier: TIER_GOLD
lifetime_spend_cents: 9007199254740993
avatar_digest: "\237\206\320\201"
tags: "early-adopter"
tags: "tea"
signed_up_at {
  seconds: 1709285400
}
```

## Where JSON differs from the wire

64-bit integers are strings, because JavaScript numbers lose precision past 2**53:
`9007199254740993` would come back as `9007199254740992`. Bytes are base64. Enums
are names. Timestamps are RFC 3339 strings. Field names are camelCase unless you ask
otherwise. Default values are left out. None of that changes the binary encoding.
