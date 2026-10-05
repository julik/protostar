# WS12: examples, the plain-protostar playbooks

Short, runnable playbooks under `examples/` for people who use protostar on its own,
with none of the Google gem around. Each playbook answers one question a newcomer has,
in the fewest lines that really run. Read the WS4 and WS5 reports first for the native
API and the CLI, and `llm/instructions/conventions.md` for the rules.

## Shape

```
examples/
  README.md                          the index: one line per playbook, in order
  01_compile_a_proto/                how do I turn a .proto into Ruby code?
  02_read_a_message/                 how do I unserialize bytes from the wire?
  03_compose_and_send_over_http/     how do I build a message and ship its bytes?
  04_json_for_debugging/             how do I look at a message, or talk to a JSON API?
```

Each playbook directory holds:

- `README.md`: the playbook. Plain prose, imperative, short sentences, one code fence
  per step, each fence doing one thing. It shows the exact commands and the exact Ruby,
  and what the reader will see when they run it. No marketing, no theory beyond one
  sentence where a concept must be named.
- The `.proto` file(s), small and realistic (an order with line items, a customer with
  an address, that kind of thing; no `Foo` and `Bar`).
- The generated `*_pb.rb`, committed, so the reader can see what the compiler produced.
- `run.rb` (or a couple of scripts where the playbook has a client and a server): the
  code from the README, runnable with `ruby run.rb` from that directory after
  `bundle install`.
- A `Gemfile` with `gem "protostar", path: "../.."` and nothing else unless the playbook
  needs it (`webrick` for the HTTP server is fine; nothing from Google).

## The playbooks

1. **Compile a proto.** Write the `.proto`, run `protostar compile -I . --ruby_out=.
   orders.proto`, open the generated file and read it (the DSL is meant to be read),
   `require_relative` it, instantiate a message. Also show the Rake task form and one
   sentence on `protoc --plugin=protoc-gen-protostar` for teams still on protoc, and on
   `--grpc_out` and `--rbs_out` existing.
2. **Read a message from the wire.** Bytes arrive as a String (from a file, a socket, an
   HTTP body): `Order.decode(bytes)`, read scalars, a nested message, a repeated field,
   a map, an enum, check presence with `has_x?`, see `unknown_fields`, `inspect` and
   `to_h`. Then the length-prefixed stream form with `decode_delimited` over an IO, for
   many messages in one file. One paragraph on `Order.view(bytes)` for reading two
   fields out of a huge message without decoding the rest, with a timing the reader can
   reproduce.
3. **Compose a message and send it over HTTP.** Build with `Order.new(...)` and with
   accessors, `encode`, `Net::HTTP` POST with `Content-Type: application/x-protobuf`,
   and a 30-line receiving server (stdlib `webrick` or `socket`) that decodes the body
   and replies with another encoded message; the client decodes the reply. Two
   scripts, `server.rb` and `client.rb`, and the README shows both terminals.
4. **JSON for debugging and interop.** `to_json`, `decode_json`, the options that matter
   (`emit_defaults`, `preserve_proto_field_names`), `to_text` for a protoc-style dump, and
   a sentence on where JSON differs from the wire (int64 as strings, bytes as base64).

## Keeping them honest

- `test/examples_test.rb` runs every playbook's scripts in a subprocess from its own
  directory with the repo's `lib` on the load path (no `bundle install` needed in CI),
  starts the HTTP server for playbook 3 on a free port and runs the client against it,
  and asserts the output lines the READMEs promise. Examples that rot fail CI.
- The same test asserts that every Ruby fence in a README is byte-identical to the
  script it came from (mark fences with a comment like `# examples/02_read_a_message/run.rb`
  on their first line, and have the test compare), so prose and code cannot drift.
- `rake examples:regenerate` recompiles every playbook's `_pb.rb` with the CLI, and the
  test checks the committed files are current.

## Voice

Write the READMEs the way Julik writes his gem READMEs: direct, imperative, short
sentences, a dry remark at most once per playbook. Assume a competent Ruby developer
who has never touched protobuf. Say what the reader types and what they see.

## Out of scope

Rails integration, gRPC, the shim, pbbuilder, performance tuning. Each of those gets
its own playbook later.
