# Streaming with the Builder

A protobuf message on the wire is a run of tag-value pairs. There is no header, no field
count, no footer, and a reader merges whatever it is given: the last value of a scalar
wins, repeated fields concatenate, and a sub-message that appears twice is merged into one.
So a writer never needs to know a message in advance to start sending it. What it has to
hold back is anything with a length in front, because the length must be known before the
first byte of the value goes out.

`Protostar::Builder` writes as the block runs, so how much it holds is decided by the shape
of the message and by a few options. This page has the measured cost of each case.

## The numbers

`script/streaming_measure.rb` builds each shape into a sink that counts bytes and keeps
none. "Held" is the peak growth of `ObjectSpace.memsize_of_all` for Strings and Arrays
after a full GC, sampled inside the block and inside the sink (so a copy that exists only
for the moment of a write is seen). Ruby 3.4.1 without YJIT, Apple M-series; payload lines
are 1 KiB.

| Shape | On the wire | Sink writes | Held at peak | Time |
|---|---|---|---|---|
| top-level repeated string | 100 MB | 1,600 | 0.06 MB | 0.15 s |
| the same, `buffer: 0` | 100 MB | 102,400 | < 0.01 MB | 0.20 s |
| 1,000 top-level nested messages of 100 KB | 97.7 MB | 2,000 | 0.13 MB | 0.14 s |
| one nested message of 100 MB | 100 MB | 2 | 128 MB | 0.14 s |
| the same, two levels down | 100 MB | 2 | 128 MB | 0.16 s |
| 10 MB under 1 / 10 / 100 levels | 10 MB | 2 | 16 MB | 0.01 / 0.02 / 0.05 s |
| one nested message of 100 MB, `chunk_nested_at: 65_536` | 100.01 MB | 3,200 | 0.13 MB | 0.15 s |
| the same, two levels down | 100.01 MB | 3,200 | < 0.01 MB | 0.20 s |
| 10 MB under 100 levels, `chunk_nested_at: 65_536` | 10.06 MB | 320 | < 0.01 MB | 0.08 s |
| 100 MB in a `DELIMITED` message field | 100 MB | 1,601 | < 0.01 MB | 0.15 s |
| 10 M packed int32 | 19.1 MB | 2 | 32 MB | 5.0 s |
| 10 M expanded int32 | 28.6 MB | 458 | < 0.01 MB | 6.0 s |
| `Builder.each`: 1,000 messages of 100 KB | 97.7 MB | 2,000 | 0.25 MB | 0.14 s |

Before this work the 100 MB nested message held 256 MB (its buffer, then a copy of it in
the top-level buffer), the 10 MB one held 32 MB at any depth, the packed run 116 MB, and
the expanded run was never written before the end, so it held 32 MB.

## Six degrees of streaming

### 1. The top level is free

Each top-level field is complete the moment it is written, so it can go out at once. The
builder collects them in a buffer of `buffer:` bytes (64 KiB by default) and writes the
buffer to the sink when it fills: 100 MB of top-level strings went out in 1,600 writes and
the builder never held more than its buffer. Repeated fields stream element by element.

`buffer: 0` writes every top-level field as it completes, for a sink that buffers on its own
(a `Zlib::GzipWriter`, a socket with Nagle, an `ActionController::Live` stream): the same
100 MB became 102,400 writes and took 0.20 s instead of 0.15.

### 2. One nesting level at a time

A length-delimited nested message must be held until it closes, because its length comes
first. Only that message is held: its earlier siblings are already out, and its parent's
later fields come after it. A thousand top-level children of 100 KB held 0.13 MB, about one
child at a time.

When the parent is the top level and the child is larger than the buffer, the child goes to
the sink as it is, in the same call as its tag and length (IO and StringIO take several
Strings per `write`; other sinks get two calls). Before, it was first copied into the
top-level buffer, which is why one 100 MB nested message held 256 MB and now holds 128 MB:
the child's own buffer, grown by doubling.

Deeper down, each level still copies its child into its own buffer when the child closes,
and frees the child's. That costs time, not memory: 10 MB under 100 levels takes 0.05 s
against 0.01 s under one, and holds 16 MB either way. Splicing children into their parents
without copying would save those 40 ms per 10 MB per hundred levels at the price of an
allocation per nested message on every build, so the builder copies.

### 3. Chunking a large nested message through merge semantics

A reader merges several occurrences of the same singular message field into one message. So
a nested message being built can be written in pieces: when its buffer passes a size, write
what it has as one occurrence of the field, start a fresh buffer, carry on. Repeated members
concatenate across the pieces, and a singular member set in one piece stays set.

```ruby
Protostar::Builder.write(io, Acme::Export, chunk_nested_at: 64 * 1024) do |pb|
  pb.report do
    rows.each { |r| pb.lines r.to_csv }   # goes out every 64 KiB
  end
end
```

With `chunk_nested_at: 65_536`, a 100 MB nested message held 0.13 MB instead of 128 MB and
took the same time. Each piece costs its tag and length, 4 bytes for a 64 KiB piece, so the
100 MB grew by 6 KB. A piece that fills its parent past the size writes the parent's piece
too, outwards to the top level: 10 MB under 100 levels went out in 160 pieces per level,
60 KB of extra tags and lengths, and took 0.08 s against 0.05 s.

The pieces read back as one message in protostar's decoder, and in google-protobuf's: the
builder tests split every nested message of random messages from five of protobuf's own test
files (proto2, proto3, maps, groups and `DELIMITED`, editions) at 1 and at 24 bytes, and
compare what both decoders make of the pieces with what they make of the whole.

What is never split: an element of a repeated message field, since two occurrences there are
two elements; a map entry's value, since a repeated key replaces; anything inside a group,
whose end tag has not been written yet; and anything inside `cache!`, whose bytes are stored
as one fragment. A message inside a repeated element can still be split, into that element.

The precondition is that no piece changes what an earlier piece said. That is the builder's
default, `overwrites: false`, and `chunk_nested_at:` refuses to run without it (or with
`repeated: :replace`, which holds lists until their message ends). The output does repeat a
singular message field on the wire, which every conforming reader merges, but a reader that
was promised no field repeats (the lazy readers' own `overwrites: false`) would see only the
first piece. Do not chunk for such a reader.

### 4. Groups and `DELIMITED` need no buffer

A proto2 group, or an editions field with `features.message_encoding = DELIMITED`, has a
start tag and an end tag instead of a length. The builder writes it in place: its fields go
straight into the enclosing buffer, and at the top level straight to the sink. 100 MB in a
`DELIMITED` field held nothing measurable, the same as 100 MB at the top level.

A schema made for streaming can say so: mark the large nested messages `DELIMITED`, and the
builder streams them with no option at all, for every reader that implements editions.
Messages nested inside a delimited field are still held one at a time, as in 2.

### 5. Sequences of messages

For a log-style file or gRPC-ish framing, `Builder.each` writes one message per element of a
collection, each with its length as a varint in front, as `encode_delimited` does:

```ruby
Protostar::Builder.each(file, Acme::Event, events) do |pb, event|
  pb.name event.name
  pb.at event.created_at
end
Acme::Event.decode_delimited(file)  # one at a time
```

Each message is held until it ends, since its length comes first, and then written: a
thousand messages of 100 KB held 0.25 MB. With `buffer: 0` every message is its own write.

### 6. Packed fields are held until their message ends

A packed repeated scalar is one length-delimited run per field, so it must be held whole.
The builder collects each packed field's values across calls and writes the run when its
message ends. Varint runs are now kept as their wire bytes: 10 M int32 held 32 MB (the run's
String at its doubled capacity) for 19 MB on the wire, where it held 116 MB as an Array of
Integers. Fixed-width runs are kept as Arrays, at most twice their wire size.

Expanded encoding (`[packed = false]`, or editions `features.repeated_field_encoding =
EXPANDED`) writes a tag per element, so it streams element by element: the same 10 M values
held nothing measurable and went out in 458 writes, at 28.6 MB on the wire instead of 19.1.

## No overwrites means more streaming

By default a builder writes each singular field once per message and raises on a second
write, saying that this is a deliberate promise and naming `overwrites: true` as the way
out. The promise is what lets the builder stream: nothing written can be contradicted later,
so it can go out at once, and a nested message can be split into pieces that every reader
merges to the same result. `chunk_nested_at:` requires it.

`overwrites: true` keeps the permissive behaviour: a later value is written as well, and wins
when read. Such output relies on readers applying last-wins, and the builder cannot split
nested messages for it, so it holds more.

## Sinks

A sink is anything that takes bytes: an object answering `write` (an IO, a socket, a Rack
hijacked IO, an `ActionController::Live` stream, a `Zlib::GzipWriter`), `<<` (an Array, an
`Enumerator::Yielder`), or `call` (a Proc). `write` is preferred when a sink has both. A String is appended to and switched to binary encoding once. Every chunk is
a binary String; nothing is transcoded. An IO or StringIO is handed the builder's own buffer,
since it copies what it writes; any other sink gets a copy it may keep, which cost 0.03 s per
100 MB in the table above (a `/dev/null` IO matches the old builder to the millisecond). The
sink's `flush` is called once, when the message is done.

`Builder.each_chunk` turns the build into an Enumerator of chunks, for a Rack body or
anything that pulls. The block runs when the Enumerator is iterated, and again on every
iteration:

```ruby
[200, {"content-type" => "application/x-protobuf"},
  Protostar::Builder.each_chunk(Acme::Report, buffer: 16 * 1024) { |pb| ... }]
```

When the sink raises, the error keeps its class and gets the field being written added to
its message, so a client going away mid-response reads as
`Errno::EPIPE: Broken pipe (while writing friends[812])`.

## Rules of thumb

- Large repeated data belongs at the top level, or in a `DELIMITED` field: both stream with
  no option.
- A large singular nested message that cannot change schema: `chunk_nested_at:` bounds the
  builder to about that size per open level, for 4 bytes per piece.
- A large element of a repeated message field is held whole, whatever the options. If one
  element can be huge, it is a candidate for its own message in a `Builder.each` sequence.
- A huge packed run is held whole too; expanded encoding trades 50% more bytes for none.
- Prefer `buffer: 0` only when the sink buffers on its own; otherwise the default 64 KiB
  makes far fewer writes for the same memory.
