# Note: field overwrites by repetition, on both sides of the wire

Protobuf lets a writer emit the same field more than once. A reader must then apply
the merge rules: the last occurrence of a scalar or oneof member wins, repeated fields
concatenate, and a sub-message that appears twice is merged field by field. Hardly any
writer does this on purpose, and it is a poor feature for readers, but it has a use on
the writing side.

## Reading (WS8 views, WS11 lazy readers)

Because of last-wins, a reader that wants the value of one scalar cannot stop at its
first occurrence; it has to scan to the end of the enclosing message, or build an index
first. WS8's views pay that once per view. WS11's lazy readers will offer an explicit
caller promise, `overwrites: false`, meaning "no field occurs twice in this message", so
the reader may seek per field and return at the first hit. The promise is never the
default and is documented as silently returning the first value when broken.

## Writing (WS9's streaming builder, and anyone emitting bytes)

When the output is strictly write-only, repetition is a tool:

- A scalar that becomes known late can be appended at the end instead of buffering the
  whole message to patch it in place, since the later occurrence wins. A builder that
  has already written `status: PENDING` can emit `status: DONE` at the end and the
  reader sees `DONE`.
- Fields of a nested message can be added after that message was written by emitting
  the nested message again with only the new fields; readers merge the two. That lets a
  streaming builder close a nested block early and still append to it later without
  rewriting its length prefix.
- Repeated fields need no run to be contiguous, so elements can be interleaved with
  other fields as they arrive.

The costs: the bytes get larger, a reader must do the merge work above, and anything
built on the `overwrites: false` promise reads such output wrongly. So a builder should
only use repetition when asked (an explicit option, off by default) and should say in
its docs that the output then relies on readers honouring merge semantics, which every
conforming implementation does, including protostar's eager decoder and WS8 views.
