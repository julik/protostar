# WS9: pbbuilder on protostar, and the streaming builder

Two deliverables. First, proof: `cheddar-me/pbbuilder`'s own test suite runs unchanged on
the google-protobuf shim. Second, the better API: `Protostar::Builder`, a streaming
builder that writes wire bytes as the DSL runs and caches fragments as bytes, with a
pbbuilder branch whose internals sit on it behind the same public DSL. Read the WS3,
WS5 and WS6 reports first, and the pbbuilder section of the plan in
`llm/instructions/genesis.md`'s companion notes below.

## What pbbuilder does today, from its source

`lib/pbbuilder.rb` is a `BasicObject` DSL over a Google message object graph. Every
contortion comes from building that graph through the reflection API: maps masquerade as
repeated message fields (`label :repeated`, `type :message`, the entry as `subtype`) so it
guesses with `respond_to?(:to_hash)`; unset sub-messages read as nil so it does
`@message[name] ||= descriptor.subtype.msgclass.new`; `RepeatedField` takes only exact
instances so it rebuilds hashes with `msgclass.new`; fragment caching (`merge!`) stores
`to_h` hashes and walks them field by field; `build` is a monkey-patch on
`Google::Protobuf::MessageExts::ClassMethods`; type errors surface as
`Google::Protobuf::TypeError` from `method_missing` with no field path.

## Part one: pbbuilder on the shim

- Clone `https://github.com/cheddar-me/pbbuilder` at its current `main` into
  `tmp/pbbuilder` (record the commit in your report), and add a script
  `script/pbbuilder_suite.rb` that runs its test suite with a generated Gemfile pointing
  `google-protobuf` at `shims/google-protobuf` by path and `pbbuilder` at the clone,
  with the Rails versions its `Appraisals` file names that are installable without
  native trouble (Rails 7.2 at least). Nothing from the clone is committed.
- Every pbbuilder test passes, or the failure is explained in the report as a shim gap
  (then fix the shim, keeping the change minimal and listed) or a pbbuilder bug.
- Add `rake shim:pbbuilder` and a CI step in the `shim` job that runs it.

## Part two: `Protostar::Builder`

Protobuf's wire format merges by concatenation: a repeated field appends, a singular
field takes the last value, a sub-message merges, so a builder does not need a message
graph. `Protostar::Builder` binds to a message class (or descriptor) and writes tags and
values to a `Wire::Writer` as the DSL runs.

```ruby
bytes = Protostar::Builder.build(Acme::Person) do |pb|
  pb.name "Jane"                       # writes the field now
  pb.friends(people) { |p| pb.name p.name; pb.id p.id }   # one element per iteration
  pb.address { pb.street "x" }         # a nested block: child buffer, then length-prefixed
  pb.attrs("a" => "b")                 # a map
  pb.created_at Time.now               # coerced to Timestamp
  pb.extract! user, :email, :phone     # fields straight from an object
  pb.cache!("person/#{id}") { pb.bio bio }   # bytes cached, a hit appends them
end
msg = Protostar::Builder.message(Acme::Person) { |pb| ... }   # decoded when an object is wanted
Protostar::Builder.write(io, Acme::Person) { |pb| ... }       # streams
```

Read `llm/outputs/notes-field-overwrites.md` before designing the writer: protobuf's
overwrite-by-repetition can make a strictly write-only output cheaper.

Rules: a nested block opens a child `Wire::Writer`, and the parent writes its tag,
length and bytes when the block closes; packed scalars are buffered per field and
flushed at the end of the enclosing message, nothing else is buffered; the cache is a
pluggable store (`cache_store:` responding to `read`, `write`, `fetch`, so Rails'
`Rails.cache` fits) keyed as given, holding the bytes the block produced; partials and
collections pass the same builder down with no state swapping; typing and coercion come
from the descriptor (`Time` and `DateTime` to `Timestamp`, numeric seconds to
`Duration`, a Hash to a map or a message, any object with `to_h` to a message, a
message instance written as its encoded bytes); errors raise `Protostar::Builder::Error`
with the field path. `Protostar::Message.build { |m| ... }` exists natively for the
non-streaming case.

A `BasicObject` DSL is not required; a plain object whose field methods are generated
from the descriptor (one `method_missing`-free method per field, like the message
accessors) is faster and debuggable. Keep `::Kernel` out of user code.

## Part three: pbbuilder on the builder

A branch of the clone (`tmp/pbbuilder-protostar`, with a patch file committed under
`llm/outputs/ws9-pbbuilder.patch`) where `Pbbuilder`'s internals delegate to
`Protostar::Builder` behind the same public DSL and the same ActionView template
handler, `cache!` and `cache_if!` included, so pbbuilder's own suite still passes with
the shim out of the picture. Measure allocations and time for a representative template
(a message with a repeated nested message of 1,000 items and fragment caching) in three
configurations: pbbuilder on the real google-protobuf gem (install it in a throwaway
GEM_HOME for the measurement only), pbbuilder on the shim, pbbuilder on the builder.
Numbers in the report.

## Testing

`test/builder/`: every DSL form above, nested and repeated and map writes compared byte
for byte with encoding the equivalent message, the cache store with a hit and a miss,
coercions, error paths, streaming to an IO, oneof last-wins, a proto2 message with
groups, and a property test: for random messages from `test/support/random_message.rb`,
a builder block generated from `to_h` produces bytes that decode to an equal message.

## Out of scope

Changing pbbuilder's public DSL, Rails 7.1's template handler regression, publishing
the pbbuilder fork.
