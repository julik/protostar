# Error messages that do not say what went wrong

**Status:** small, not scheduled. Found by WS10 on 2026-10-06.

1. **Cross-pool assignment names the same type on both sides.** Assigning a shim
   `Google::Protobuf::Timestamp` to a native field (or the reverse) raises
   `expects a google.protobuf.Timestamp ..., got <Google::Protobuf::Timestamp ...>`. The
   two classes come from different pools (the native generated pool and the shim's own),
   which is by design, but the message should say so: name the Ruby class and the pool or
   registry each side belongs to, and point at `docs/migration.md`'s two-pools section.
   Where: `lib/protostar/message/coercion.rb`, `raise_type`.
2. **The shim's `RepeatedField#<<` error has an empty field name**: `integral field ''`.
   Fill in the field name, or drop the field clause when the RepeatedField was built
   standalone with `RepeatedField.new(:int32)`. Check what the C gem prints for the same
   case and match it where it is sensible. Where: `shims/google-protobuf/lib/google/protobuf/repeated_field.rb`.

Both are a few lines each, with a test apiece.
