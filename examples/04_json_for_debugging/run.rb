# frozen_string_literal: true

require "bundler/setup"
require "json"
require_relative "customer_pb"

customer = Crm::Customer.new(
  id: "C-42",
  full_name: "Ada Lovelace",
  tier: :TIER_GOLD,
  lifetime_spend_cents: 9_007_199_254_740_993,
  avatar_digest: "\x9f\x86\xd0\x81".b,
  tags: ["early-adopter", "tea"],
  signed_up_at: Time.utc(2024, 3, 1, 9, 30)
)

puts customer.to_json

puts JSON.pretty_generate(customer)

puts customer.to_json(emit_defaults: true, preserve_proto_field_names: true)

payload = <<~JSON
  {"id": "C-43", "fullName": "Grace Hopper", "tier": "TIER_SILVER",
   "lifetimeSpendCents": "1200", "signedUpAt": "2024-05-02T10:00:00Z"}
JSON
grace = Crm::Customer.decode_json(payload)
puts grace.inspect
puts grace.signed_up_at.to_time.utc

newer = '{"id": "C-44", "favouriteColour": "teal"}'
begin
  Crm::Customer.decode_json(newer)
rescue Protostar::JSON::ParseError => e
  puts e.message
end
puts Crm::Customer.decode_json(newer, ignore_unknown_fields: true).inspect

puts customer.to_text
