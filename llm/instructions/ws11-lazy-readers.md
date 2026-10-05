# WS11: lazy readers over a bag of bytes

"Here is a bag of bytes, here is the schema, give me message objects with lazy reader
methods that unmarshal on demand without extra allocations." A separate class family
built for that one job, for a specific customer. Read the WS3 and WS8 reports first:
WS8's views are the nearest relative, and parts of their generated scanners may be reused,
but the contract here is different and both families stay.

## How this differs from WS8 views

| | WS8 `Klass.view` | WS11 `Protostar::Lazy` |
| --- | --- | --- |
| Schema | generated classes via `Types.define` | a schema handed over at runtime, no constants needed |
| Creation cost | scans every top-level tag, builds an index Array | one object; nothing scanned until a reader is called |
| A reader call | index lookup, decoded value memoised | scans for that field, returns the value, memoises nothing by default |
| Repeated fields | `View::Repeated` wrapper per read | block iteration with no per-element allocation; an Array only when asked |
| Nested messages | a nested view object, memoised | a nested lazy object per read, or a reusable cursor in flyweight mode |
| Target | general read-only use | hot paths that read a few fields out of many messages |

## API

```ruby
schema = Protostar::Lazy.schema(descriptor_set_bytes)            # or a Schema::Pool, a Schema::File, or .proto sources compiled on the fly
schema = Protostar::Lazy.schema(proto_source: "...", name: "x.proto", include_paths: [...])

reader = schema.reader("acme.Person")                            # a frozen, Ractor-shareable reader class, cached per schema
person = reader.wrap(bytes)                                      # one allocation; bytes may be a String or IO::Buffer, with offset: and length:
person.name                                                      # scans the bytes for field 1, returns the String; nothing retained
person.id                                                        # an Integer; no allocation beyond the Integer itself when it is not immediate
person.has_name?, person.which_contact, person.created_at.seconds
person.each_friend { |f| f.name }                                # yields a lazy object per element, or in flyweight mode the same cursor re-pointed
person.friends                                                   # an Array of lazy objects, only when asked
person.friend_count, person.friend_at(2)                         # for repeated fields: count and index without materialising
person.attrs_at("key"), person.each_attr { |k, v| }               # maps: lookup by key by scanning, iteration without a Hash
person.unknown_fields { |number, wire_type, bytes| }             # block form, no Array
person.to_message, person.to_h, person.bytes                     # the eager escape hatches
reader.wrap(bytes, index: true)                                  # opt-in: build a compact offset index on first read, one Array, for repeated reads
reader.wrap(bytes, flyweight: true)                              # opt-in: nested and repeated readers reuse one cursor; the yielded object is only valid inside the block
```

Rules:

- Merge semantics are protobuf's (last occurrence wins for scalars and oneofs, repeated
  concatenates, sub-messages merge), so a scalar reader scans to the end of the message
  unless `index: true` was given. Document that cost honestly; the customer's messages
  decide which mode fits.
- Allocation budget, enforced by tests on Ruby 3.4 with `GC.stat` deltas: `wrap` is one
  object; a scalar read allocates nothing beyond the value (Strings and bytes are one
  `byteslice`; Floats and large Integers are what Ruby makes them); a nested read is one
  object, or zero in flyweight mode; `each_x` allocates one object for the whole
  iteration in normal mode and zero in flyweight mode; `has_x?`, `which_x`, `x_count`,
  `x_at` allocate nothing.
- Readers are generated as Ruby source per message type, like WS3 and WS8, with the
  field tags baked into one scanning `case`, and the reader classes are frozen and
  `Ractor.shareable?`. A wrapped object over a frozen String is shareable too.
- Closed-enum unknown numbers, packed and unpacked repeated fields, groups and
  delimited messages, UTF-8 validation on string reads, and `DecodeError` with offsets
  all behave as the eager decoder does; a malformed message is reported by the reader
  that trips over it, not up front.
- The schema can come from a `FileDescriptorSet` (bytes or file), a `Schema::Pool`, a
  `Schema::File`, or `.proto` sources compiled through `Protostar::Compiler` in memory.
  Nothing requires generated files or constants.

## Testing

- Parity with the eager decoder over every message type in the corpus goldens with
  random messages from `test/support/random_message.rb`, in normal, `index: true` and
  flyweight modes: every reader agrees with the decoded message field by field.
- The allocation budget above, per reader kind, with a positive control.
- Schema from each source form; a reader for a type that is not in the schema raises.
- Ractor: reader classes and a wrapped frozen String cross the boundary; wrapping and
  reading inside a Ractor.
- Benchmark in `bench/lazy_bench.rb`: reading two fields from a large message and from a
  stream of 10,000 small messages, against eager decode and WS8 views, with allocation
  counts, in the report.

## Open questions, to be settled with the customer before or during the work

- Typical message size and how many fields are read per message; this decides the
  default between scan-to-end and `index: true`.
- Whether the schema arrives at runtime (descriptor set bytes) or is known at build time.
- Whether flyweight iteration is acceptable to their code (the yielded object dies with
  the block).
- Ruby version and whether Ractors are in play.
