# Examples

Playbooks for using protostar on its own. Each one answers one question, runs as
shown, and is checked by the test suite so it stays that way. Read them in order.

1. [Compile a proto](01_compile_a_proto/): turn a `.proto` into Ruby code.
2. [Read a message from the wire](02_read_a_message/): turn bytes back into an object.
3. [Compose a message and send it over HTTP](03_compose_and_send_over_http/): build a message and ship its bytes.
4. [JSON for debugging and interop](04_json_for_debugging/): look at a message, or talk to a JSON API.

Every playbook has its own `Gemfile`. Run `bundle install` in its directory, then
the commands its README shows.
