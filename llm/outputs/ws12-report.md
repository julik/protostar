# WS12 report: the plain-protostar playbooks

## What was built

| Path | Contents |
|---|---|
| `examples/README.md` | the index, four links in order |
| `examples/01_compile_a_proto/` | `orders.proto`, `orders_pb.rb`, `run.rb`, `Rakefile` (a `rule` plus `task protos`), `Gemfile` (protostar and rake), `README.md` |
| `examples/02_read_a_message/` | `orders.proto`, `orders_pb.rb`, `run.rb`, `view.rb`, `order.binpb` and `orders.binpb` (162 and 69 bytes), `sender/` (a newer `orders.proto` with `gift_note = 7`, its `_pb.rb`, and `write.rb` that wrote the two `.binpb`), `Gemfile`, `README.md` |
| `examples/03_compose_and_send_over_http/` | `checkout.proto`, `checkout_pb.rb`, `client.rb` (Net::HTTP), `server.rb` (stdlib `socket`, 30 lines), `Gemfile`, `README.md` |
| `examples/04_json_for_debugging/` | `customer.proto` (imports Timestamp), `customer_pb.rb`, `run.rb`, `Gemfile`, `README.md` |
| `script/examples.rb` | `regenerate` and `check`: every directory under `examples/` holding `.proto` files is compiled with `exe/protostar compile -I . --ruby_out=...` from inside it |
| `Rakefile` | `examples:regenerate`, `examples:check` |
| `test/examples_test.rb` | below |

Every output block in the READMEs was pasted from a real run on Ruby 3.4.1. The one number that
changes between runs (the view timing in 02) is shown as I measured it and the README says so.

### README conventions the test relies on

- A fence whose first line is `# examples/<playbook>/<file>` (`//` in a `.proto` fence) is a slice
  of that file. A file may be split over several fences, one per step; its slices joined by one
  blank line are the file, byte for byte. Every file in a playbook directory except `_pb.rb`,
  `.binpb` and the README must be shown in full; `01` also shows its `orders_pb.rb`.
- A `console` fence is a terminal: `$ ` lines are commands, the lines under one are its output.
  Every command shown is run by the test or is on an explicit skip list (`bundle install` only).
- Scripts begin with `require "bundler/setup"`, so `ruby run.rb` works after `bundle install` in
  the playbook directory, as the spec asks. The test runs them with `BUNDLE_GEMFILE` set to the
  repo's Gemfile and `-I lib`, so CI needs no per-playbook install.

## Tests

`test/examples_test.rb`: 7 runs, 109 assertions, about 7 s.

| Test | Covers |
|---|---|
| `test_the_index_lists_every_playbook_in_order` | index links all four in order; no other playbook directories |
| `test_fences_are_the_files_byte_for_byte` | the slice rule above, every fence marked, every file shown |
| `test_generated_code_is_current` | `script/examples.rb check` |
| `test_every_command_in_the_readmes_prints_what_they_promise` | `ruby run.rb` (01, 02, 04), `ruby view.rb`; `bundle exec protostar compile ...` (all four) and `bundle exec rake protos` (01) in a scratch copy with the `_pb.rb` deleted, output compared and the regenerated files equal to the committed ones. The Rake run puts a `protostar` shim first on `PATH` |
| `test_the_view_is_faster_than_decoding` | the claim in 02 (measured 133 ms vs 17 ms; the assertion is only `view < decode`) |
| `test_the_sender_wrote_the_committed_bytes` | `sender/write.rb` in a scratch copy reproduces both `.binpb` files byte for byte |
| `test_the_http_server_and_client_talk` | server on a free port (`PORT`), waits for its first line, runs the client, compares the client's output, stops the server with INT (its trap exits cleanly) and compares the server's whole output with the port normalised to 9292 |

Output comparison normalises two things only: `N.N ms` timings, and on Ruby < 3.4 the old
`Hash#inspect` style (`:a=>`, `"k"=>`) to 3.4's, since `Message#inspect` and `to_h` embed it.
The 02 README says the old style is what readers before 3.4 will see.

A mutation check (changing a fence line and an expected output line in 01, appending a line to
`client.rb`) failed the test as it should.

`bundle exec rake`: 2122 runs, 89347 assertions, 0 failures, 335 skips (all pre-existing), standard
clean, on Ruby 3.2.2, 3.4.1 and 4.0.0. Standard covers `examples/` unscoped (checked by planting
a violation there); the example code, Gemfiles and Rakefile are lint-clean.

## Deviations from the spec, and why

1. **The HTTP server uses `socket`, not `webrick`.** webrick is not in the repo's bundle, and the
   test must run without installing a playbook's Gemfile. The spec allows either.
2. **01's Gemfile adds `rake`**; without it `bundle exec rake protos` fails in that directory.
3. **02 ships fixtures from a "sender"** with a newer schema, so that unknown fields arrive the way
   they do in life (a field added upstream) rather than from hand-made bytes. The sender's
   `write.rb` also shows `encode_delimited`.
4. **Fences per step, not one fence per script**: the spec asks for both one fence per step and
   fences byte-identical to scripts; the slice rule above satisfies both.
5. `script/examples.rb check` also exists as `rake examples:check`, mirroring `conformance:check`.

## API rough edges found

Nothing under `lib/` was changed. Each playbook shows the path that works today.

1. **A Ruby `Time` cannot be assigned to a Timestamp field.** google-protobuf 4.36 accepts it in
   `new` and in the writer.
   ```ruby
   # examples/04_json_for_debugging
   Crm::Customer.new(signed_up_at: Time.utc(2024, 3, 1))
   # => Protostar::TypeError: crm.Customer.signed_up_at expects a google.protobuf.Timestamp or a Hash, got 2024-03-01 00:00:00 UTC
   ```
   The gem gives `t: <Google::Protobuf::Timestamp: seconds: 1709251200, nanos: 0>` for the same
   call. The playbook uses `Protostar::Google::Protobuf::Timestamp.from_time(...)`.
2. **Well-known types have only the long name** `Protostar::Google::Protobuf::Timestamp` in the
   native world. Fine for generated code, heavy in user code; there is no shorter alias.
3. **`--rbs_out` describes google-protobuf's classes, not protostar's.** For `01`'s `orders.proto`
   it writes `class Order < ::Google::Protobuf::AbstractMessage`, `items` as
   `::Google::Protobuf::RepeatedField`, a `status_const` reader and string writers that accept
   `::Symbol`. The native class is `< Protostar::Message`, `items` is an `Array`,
   `respond_to?(:status_const)` is false, and `order.id = :x` raises `Protostar::TypeError`.
   WS4 did this on purpose (protoc parity); a plain-protostar user running Steep against it gets
   wrong types. The 01 README says so in one sentence.
4. **`pp message` does not wrap.** `Message#pretty_print` is `q.text(inspect)`, so 02's order
   prints as one 420-character line under `pp` too. A real `pretty_print` (a `q.group` per message,
   `q.breakable` between fields) would make `pp` useful for nested messages.
5. **`JSON.pretty_generate(message)` prints compact JSON**: `Message#to_json(_state = nil, **opts)`
   ignores the generator state. google-protobuf behaves the same, so this is not a parity gap, but
   the debugging playbook has to write `JSON.pretty_generate(JSON.parse(msg.to_json))`.
6. **`inspect` hides unknown fields.** 02's order with `gift_note` inspects exactly like one
   without it; only `unknown_fields` shows it. google-protobuf also hides them. A trailing
   `unknown: [7]` in `inspect` would have saved the reader a step.
7. **`UnknownField#value` of a length-delimited field is a BINARY String**, so a non-ASCII payload
   inspects as `"\xE2\x9C\xA8"`. Unavoidable without the schema; noted because readers will meet it.
8. `Message#inspect` and `to_h` output depend on the Ruby version through `Hash#inspect` (3.4
   changed it). Not protostar's doing; the test normalises it.

## For the next workstreams

- Adding a playbook: create `examples/NN_name/`, add it to `PLAYBOOKS` in the test and to the
  index, mark every fence, and run `rake examples:regenerate` after touching a `.proto`.
- A command shown in a `console` fence that the test does not know fails the test on purpose;
  teach `test_every_command_in_the_readmes_prints_what_they_promise` to run it or add it to `SKIPPED`.
- If rough edge 1 or 4 is fixed, 04's `Timestamp.from_time` and the `JSON.parse` round trip can be
  simplified; the README outputs will then need re-pasting from a real run.

## Open questions

1. Should protostar accept `Time` for Timestamp fields as the gem does?
2. Should the native emitter offer an RBS flavour that matches `Protostar::Message`?
3. Should `to_json` honour a `JSON::State` (indent) when the stdlib generator calls it?
