# Super-introspectable message classes

**Status:** feature lead from Julik, 2026-10-06. Not scheduled.

> I want the class of the proto message that we produce to be super-introspectable: which
> fields, which registry, sizes, types, and so on.

## What a class answers today

`Klass.descriptor` is the frozen `Schema::Message` (fields with `name`, `number`, `type`,
`wire_type`, `packed?`, `presence?`, `default`, `map?`, `oneof`, options, features).
`Klass.reflection` (WS14) adds `fields`, `oneofs`, `field(key)`, `get`, `set`, `set?`,
`clear`, `which`, `message_class`, `enum_module`, `each(message)`, `info(key)`.
`Protostar::Types.registry` exists, but a class does not know which registry or pool made it.
`Klass.inspect` is just the constant name. The `__fields`, `__by_number`, `__template`,
`__oneofs`, `__required` tables are private fast paths and not meant for people.

## The gap, as questions a developer asks at a console

| Question | Today | Wanted |
| --- | --- | --- |
| What fields does this have, with types and numbers, at a glance? | `descriptor.fields.map { ... }` | `Klass.inspect` and `Klass.explain` show it |
| Which registry and pool defined it, from which file? | not reachable from the class | `Klass.registry`, `Klass.pool`, `Klass.file` (`Schema::File`), `Klass.source` (file name and, when known, disk path) |
| What accessor methods were generated, and which were skipped because the name clashed? | read the generator | `reflection.accessors` listing reader, writer, `has_x?`, `clear_x`, `which_x` per field, with `skipped: [...]` |
| Which slot and presence bit does a field use? | `__fields` | `reflection.field(:x).slot`, `.presence_bit` |
| For repeated and map fields, what are the element and key/value types and classes? | `descriptor` plus `message_class` | one record per field with `element_type`, `key_type`, `value_type`, `element_class` |
| How big does it get on the wire? | nothing | `Klass.fixed_size?` and `Klass.size_bounds` (min bytes, max or `nil` for unbounded) from the descriptor; `message.encoded_size` (runs the sizer only), `message.field_sizes` (bytes per field, unknown fields included) |
| Which fields are set on this instance, and which are at their default? | `has_x?` per field | `message.set_fields`, `message.each_field { |field, value, set| }`, `message.unknown_fields.sum(&:bytesize)` |
| What options and features apply? | `descriptor.options`, `.features` | surfaced in `explain` |
| Show me the `.proto` this came from | the generated file's comments | `Klass.to_proto_source`: the message printed back as `.proto` text (a text emitter over the descriptor) |
| Which classes reference this one, and which does it reference? | nothing | `reflection.referenced_classes`, `registry.referrers(Klass)` |

## Shape

- Keep `Klass.descriptor` as the schema truth and `Klass.reflection` as the one object for
  everything per-class; make it `Enumerable` over field records and give it a readable
  `inspect`. No new `__` names.
- A `Reflection::FieldRecord` (frozen) per field with the columns above; built at
  `Types.define` time so it costs nothing later and stays Ractor-shareable.
- `Klass.registry` and `Klass.pool` are set by `Types.define`; `Klass.file` is
  `descriptor.file`.
- `Klass.explain` prints a table (`number name type label wire presence default accessors`)
  plus oneofs, options, size bounds and the source file; `Klass.inspect` becomes
  `#<Acme::Person (acme.Person) 6 fields, 1 oneof>` so it reads in a console and in `pp`.
- `message.explain` prints the same table with the instance's values, set-ness and bytes
  per field. Instance methods must not collide with field names: put them on
  `message.reflection` (an instance-bound view) and alias only the ones that cannot clash
  (`encoded_size`, `explain`) after checking the descriptor at define time, the way the
  accessors already skip reserved names.
- Views (`Klass.view_class`) get the same read-only side.
- The shim's descriptor wrappers can be thin over the same records.

## Tests

Every record column against the corpus goldens (`unittest.proto` covers every field kind),
`size_bounds` checked against real encodes of random messages, `explain` output pinned for
one message, Ractor shareability of the records, no new accessor collisions on the corpus
(a field named `explain` or `registry` must still work).

## Effort

Medium: mostly assembling what the define step already knows into one documented object,
plus the size computations and the two printers.
