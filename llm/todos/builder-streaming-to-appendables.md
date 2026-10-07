# `Protostar::Builder` writes to any appendable, and streams as far as the wire format allows

**Status:** feature request from Julik, 2026-10-07. Scheduled; a subagent picks it up
from this brief, and part of its job is to investigate and report, not only to build.

## The ask

> Our `Protostar::Builder` should just accept an appendable or IO for writing the messages
> as we go. Once a message is complete the protobuf spec should allow us at least some
> degree of streaming. Investigate.

## Where the builder stands (main, 2026-10-07)

- `Builder.write(io, klass) { |pb| ... }` exists and streams through `Wire::Writer`'s
  64 KiB buffer; `Builder.build` returns a String; `Builder.message` decodes the result.
- A nested message block gets a child buffer, because a length-delimited field's length
  precedes its bytes, so the child is held until its block ends, then tag, length and
  bytes are written. Children are reused from a spare list. A nested group (proto2
  `group`, editions `DELIMITED`) is written with start and end tags and needs no buffer.
- Packed repeated scalars are buffered per field until the enclosing message ends.
- Deep trees copy each child into its parent (measured in WS9: flat to 100 levels, then
  it shows).

## What the wire format allows, to be confirmed by the investigation

The wire format is a sequence of tag-value pairs with no header and no footer, and
readers merge whatever they get. That gives several degrees of streaming, each with a
cost, and the brief wants each one measured and documented, not assumed:

1. **Top level is free.** A top-level message's fields are self-delimiting, so a builder
   can write each field to the sink the moment it is complete; nothing about the message
   needs to be known in advance. Repeated fields at the top level stream element by
   element. This should already be the case through the 64 KiB buffer; make it true for
   any sink and make the buffer size an option (`buffer: 0` writes every completed
   top-level field at once, for sinks that are themselves buffered).
2. **One nesting level at a time.** A length-delimited nested message must be buffered
   until it closes, but only that message: its siblings before it have already gone out,
   and its parent's later fields go out after it. Memory is bounded by the largest single
   nested message, not the whole tree. Confirm the builder does exactly this and nothing
   more (no copying through every ancestor; a child buffer that is written straight to the
   sink when its parent is the top level).
3. **Chunking a large nested message through merge semantics.** A reader merges several
   occurrences of the same singular message field. So a nested message that is being
   built can be flushed in pieces: close the child buffer at a threshold, write it as one
   occurrence of the field, open a fresh child, continue; repeated members concatenate
   across the pieces and singular members set once stay set. The result decodes to the
   same message on every conforming reader (ours, the C gem, protoc's languages), and
   memory is bounded by the threshold rather than by the nested message's size. The
   cost: a few bytes per piece for the repeated tag and length, and readers do merge work.
   This is only valid while no singular member is set twice across pieces, which is the
   builder's `overwrites: false` default anyway. Make it an opt-in option
   (`chunk_nested_at: bytes`), prove it with a decode-equality test against the C gem
   through the oracle, and measure memory on a 100 MB nested message. This is the real
   "degree of streaming" question; answer it with numbers.
4. **Groups and `DELIMITED` need no buffer at all.** For editions files with
   `features.message_encoding = DELIMITED` on a field, or proto2 groups, the nested
   message streams through start and end tags. The builder should take that path whenever
   the descriptor says so, and the docs should say that a schema designed for streaming
   can use `DELIMITED` for its large nested messages.
5. **Sequences of messages.** `encode_delimited` (varint length prefix) exists for
   streams of top-level messages. The builder gets a matching form: `Builder.each(io,
   klass)` yielding a builder per message and writing each one length-prefixed as it
   completes, for log-style files and for gRPC-ish framing.
6. **Packed fields** must be buffered until the field is complete, by definition; note it,
   and note that expanded encoding (`[packed = false]`, or editions `EXPANDED`) streams
   element by element at the cost of a tag per element.

## Sinks

"Appendable" means anything that takes bytes: define the duck type as an object answering
`<<` (String, Array of chunks, `StringIO`, an `IO`, `Zlib::GzipWriter`), or `write`
(sockets, Rack hijacked IOs, `ActionController::Live` streams), with `flush` called when
the sink answers it. Also:

- `Builder.each_chunk(klass) { |bytes| ... }` and an `Enumerator` form, for Rack bodies
  and anything that pulls rather than pushes.
- Binary encoding of every chunk, never a transcoding; a sink that is a String gets
  `force_encoding` once.
- Errors raised while writing propagate with the builder's field path, so a broken pipe
  mid-message says which field was being written.

## Deliverables

- The sink duck type and the options above in `Protostar::Builder`, with `Builder.write`
  and `Builder.build` unchanged for existing callers.
- `docs/concepts/streaming.md`: what the wire format allows, the six degrees above with
  the measured costs, the chunking trick and its one precondition, and when to reach for
  `DELIMITED`. Written from the numbers, not the plan.
- Tests: every sink kind, byte-identical output across sinks and buffer sizes, the
  chunking decode-equality test against the oracle gem (skipping cleanly without it),
  bounded-memory tests using `GC.stat` or `ObjectSpace.memsize_of_all` deltas for a
  nested message far larger than the threshold, the sequence form round-tripping through
  `decode_delimited`, and the error path with a sink that raises.
- A CHANGELOG line and a README paragraph under the Builder section.

## Out of scope

Reading side streaming (that is views and the lazy readers brief), HTTP framing, gRPC.
