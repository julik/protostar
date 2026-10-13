# Moving from google-protobuf to protostar

You have an app or a gem that uses the `google-protobuf` gem, with `_pb.rb` files that
`protoc` generated. There are two ways to drop the C extension and `protoc`:

- **The native path.** Regenerate the `_pb.rb` files with `protostar compile --ruby_out`
  and use protostar's classes. No `google-protobuf` gem at all, unless another gem in the
  bundle needs one. This is the path for code you own.
- **The shim path.** Keep your `_pb.rb` files and your code. Install
  [`shims/google-protobuf`](../shims/google-protobuf/README.md), a gem named
  `google-protobuf` that provides Google's API on protostar. This is the path when the code
  that talks protobuf is not yours (`grpc`, `googleapis-common-protos-types`, a vendor SDK),
  or when you want to switch first and port later.

The two mix: native files for your own schemas, the shim for the gems that need
`Google::Protobuf`. Read [Two pools](#two-pools) before you do.

## The native path

### 1. Swap the gems and the compiler

```ruby
# Gemfile
gem "protostar", "0.1.0.beta1"
```

Wherever you ran protoc, run protostar with the same flags:

```console
$ protoc -I proto --ruby_out=lib proto/acme/person.proto          # before
$ bundle exec protostar compile -I proto --ruby_out=lib proto/acme/person.proto   # after
```

`--ruby_out` writes protostar's own `_pb.rb`. `--google_out` writes what `protoc --ruby_out`
writes, byte for byte, for the shim path. `--rbs_out`, `--grpc_out` and
`--descriptor_set_out` work too; a plugin for an existing protoc pipeline is
`protoc --plugin=protoc-gen-protostar --protostar_out=lib`.

### 2. Change the code that uses the classes

The constants keep their names: `package acme;` still gives `Acme::Person`, `ruby_package`
is honoured, and nested messages are nested constants, all by protoc's rules. Most code
keeps working: `new` with a Hash or keywords, readers and writers, `has_x?`, `clear_x`,
`encode`, `decode`, `to_h`, `==`, `encode_json`/`decode_json`, `to_json`. What changes:

| google-protobuf | protostar |
|---|---|
| `Google::Protobuf::Timestamp` and the other well-known types | `Protostar::Timestamp` (short name) or `Protostar::Google::Protobuf::Timestamp` |
| `Klass.encode(msg)`, `Klass.decode(bytes)` | the same, and also `msg.encode` |
| `msg.contact` for a oneof (the member's name) | `msg.which_contact` |
| `Klass.encode_json(msg, preserve_proto_fieldnames: true)` (a positional Hash) | keywords: `Klass.encode_json(msg, preserve_proto_field_names: true)`; the gem's spelling is accepted too |
| `RepeatedField`, `Map` (checked on every push) | plain `Array` and `Hash`, checked when the message is encoded |
| `RangeError` for an integer out of range, `Google::Protobuf::TypeError` for a wrong type | `Protostar::TypeError` for both (a subclass of Ruby's `TypeError`) |
| `Google::Protobuf::ParseError` | `Protostar::DecodeError` (binary), `Protostar::JSON::ParseError`, `Protostar::Text::ParseError` |
| `Klass.descriptor` (a `Google::Protobuf::Descriptor`) | a `Protostar::Schema::Message`; `Klass.reflection` gets and sets fields by name |
| `Google::Protobuf::DescriptorPool.generated_pool` | `Protostar.generated_pool` |

### 3. Gotchas

The examples below use this file, compiled with `--ruby_out` (and with `--google_out` for
the shim's), with `Paint = Acme::Legacy::Paint`:

```proto
syntax = "proto2";
package acme.legacy;
enum Color { RED = 0; GREEN = 1; }
message Paint {
  optional Color color = 1;
  repeated int32 sizes = 2;
  optional int32 count = 3;
}
```

**Errors.** A value out of range raises `Protostar::TypeError`, where the gem raised
`RangeError`. `rescue TypeError` catches it; `rescue RangeError` does not.

```ruby
Paint.new(count: 2**31)
# raises Protostar::TypeError: acme.legacy.Paint.count expects an Integer in int32 range, got 2147483648
```

**Closed enums.** In a proto2 file (or an editions file with `enum_type = CLOSED`) an enum
accepts only the numbers it names, as protoc's C++ and Java runtimes do. Assigning another
number raises, and decoding one puts it into the message's unknown fields, where it is kept
and written back on encode. The gem keeps such numbers in the field instead.

```ruby
Paint.new(color: 7)
# raises Protostar::TypeError: acme.legacy.Paint.color expects a value of acme.legacy.Color, got 7

seven = "\x08\x07".b # field 1, varint 7
Paint.decode(seven)                  # => #<acme.legacy.Paint>
Paint.decode(seven).color            # => :RED
Paint.decode(seven).unknown_fields   # => [#<Protostar::UnknownField 1:varint "\a">]
Paint.decode(seven).encode == seven  # => true
```

Proto3 enums are open, as everywhere: an unnamed number reads back as an Integer.

**Containers are plain.** A repeated field is an `Array`, so pushing a wrong value
succeeds, and the encode reports it:

```ruby
paint = Paint.new
paint.sizes << "big"
paint.encode
# raises Protostar::EncodeError: acme.legacy.Paint.sizes holds "big", which it cannot encode
```

**Accessors that would shadow Ruby.** A field named `hash`, `class`, `method`, `encode` or
another method every message has gets no accessor; use `msg[:hash]` and `msg[:hash] = v`.
google-protobuf behaves the same way through `method_missing`.

**Extensions** are not fields. Their bytes are kept as unknown fields and survive a round
trip; the text format and JSON read and write them by name (`[pkg.ext]`), but there is no
`msg.get_extension`. The shim has `FieldDescriptor#get`/`#set` for them.

**`_pb.rb` files written by protoc before 3.21** use a DSL (`add_file`, `add_message`) that
neither protostar nor the shim reads. Regenerate them.

## The shim path

Put the shim in the Gemfile; the
[shim's README](../shims/google-protobuf/README.md#installation) has the exact lines for
each way to install it and how to check that Bundler picked it. Then run your tests. Your
`_pb.rb` files and the code around them are unchanged, and
`Google::Protobuf::IMPLEMENTATION` answers `:PROTOSTAR`.

The shim follows the gem, not protoc, where the two differ: enums are open, integers out
of range raise `RangeError`, containers are `RepeatedField` and `Map` and check every
write.

```ruby
Paint.new(count: 2**31)          # raises RangeError: integer 2147483648 too big to convert to 'int'
Paint.new(color: 7)              # => <Acme::Legacy::Paint: color: 7, sizes: []>
Paint.new.sizes.class            # => Google::Protobuf::RepeatedField
```

What differs from the C gem is listed in
[known_differences.md](../shims/google-protobuf/test/known_differences.md): mostly
`inspect` of descriptors, map iteration order, and JSON error wording.

Gems that pin `google-protobuf` below 4 (`~> 3.18`, say) will not resolve against the
shim's 4.36.2.1 unless you override their requirement; the shim README shows how. Such
gems often ship `_pb.rb` files from protoc before 3.21, which do not load (see above).

## Two pools

Native files build into `Protostar.generated_pool` and define classes in protostar's
registry. Google-format files build into `Google::Protobuf::DescriptorPool.generated_pool`,
which the shim keeps separately with its own registry. The two never share classes:

- `Google::Protobuf::Timestamp` (the shim's) and `Protostar::Timestamp` are different
  classes over the same bytes. Assigning one where the other is expected raises, with a
  message that names the same full name on both sides; convert through the bytes
  (`Acme::Person` is the native class from the README):

  ```ruby
  google_ts = Google::Protobuf::Timestamp.new(seconds: 1_700_000_000)
  Acme::Person.new(born_at: google_ts)
  # raises Protostar::TypeError: acme.Person.born_at expects a google.protobuf.Timestamp or a Hash,
  #   got <Google::Protobuf::Timestamp: seconds: 1700000000, nanos: 0>
  Acme::Person.new(born_at: Protostar::Timestamp.decode(Google::Protobuf::Timestamp.encode(google_ts)))
  ```
- Load each `.proto` one way. Generating a file both natively and in Google format and
  loading both gives two sets of classes with the same full names, one per pool. That is
  allowed, and confusing.
- A native file that imports another must find it in the native pool: compile both with
  `--ruby_out`. A Google-format file imports Google-format files.
- `Google::Protobuf::DescriptorPool.generated_pool.lookup("acme.Person")` does not see
  native files, and `Protostar.generated_pool` does not see Google-format ones.

## gRPC

`grpc` marshals with `Klass.encode` and `Klass.decode`, which native classes have, so
`protostar compile --grpc_out` stubs work with native messages:

```console
$ bundle exec protostar compile -I proto --ruby_out=lib --grpc_out=lib proto/acme/person.proto
```

`grpc`'s gemspec depends on `google-protobuf`, so one has to be installed; with native
messages it is never loaded. Install the shim and the C extension is gone from the bundle
as well.

## A gem that depends on google-protobuf

If your gem ships `_pb.rb` files and declares `google-protobuf` as a dependency:

- To support both, keep shipping Google-format files (`protostar compile --google_out`
  makes them without protoc) and keep the dependency. Users pick Google's gem or the shim.
- To move to protostar, regenerate with `--ruby_out`, depend on `protostar`, and say so in
  your changelog: your users' code that touches your messages sees the changes above.
