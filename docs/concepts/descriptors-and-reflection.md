# Descriptors and reflection

Every generated message class answers two questions that look alike and are not:
`Klass.descriptor` says what the `.proto` says, and `Klass.reflection` says how this
particular Ruby class carries it. They have different lifetimes, and keeping them apart is
what lets descriptors be shared.

## `descriptor`: the schema

`Klass.descriptor` is a `Protostar::Schema::Message`. It knows field names, numbers,
types, labels, oneofs, defaults, options, resolved features, and the rules that follow
from them: which fields track presence, which repeated fields are packed, which enums are
closed. It is frozen and Ractor-shareable, and it knows nothing about Ruby objects.

It exists without any class. The compiler produces descriptors for files nobody will define
classes for; a pool holds them; the emitters, the shim and `to_proto` read them. One
descriptor can back several classes at once: the native registry and the google-protobuf
shim's pool each define their own class set from the same descriptor.

```ruby
d = Acme::Person.descriptor
d.full_name                       # => "acme.Person"
d.field(:emails).label            # => :repeated
d.field("born_at").message_type   # => #<Protostar::Schema::Message google.protobuf.Timestamp>
d.options.deprecated?             # => false
Ractor.shareable?(d)              # => true
```

## `reflection`: the binding

`Klass.reflection` is the bridge from that descriptor to this class and its instances. It
knows which slot a field occupies, which accessor methods were generated and which were
skipped because the name clashed with a `Message` method, which Ruby class a message-typed
field decodes into and which module an enum field maps to. It also carries the verbs that
work on an instance by descriptor rather than by method name:

```ruby
r = Acme::Person.reflection
r.fields                          # the Schema::Field list, in declaration order
r.message_class(:address)         # => Acme::Address
r.enum_module(:kind)              # => Acme::Person::Kind
r.get(person, :name)              # same as person.name, by field
r.set(person, "emails", ["a@b"])  # same as person.emails = ..., with the same checks
r.set?(person, :address)          # presence, where the field tracks it
r.which(person, :contact)         # the set member of a oneof, or nil
r.each(person) { |field, value| } # every set field with its descriptor
```

None of this can live on the descriptor without tying the descriptor to one class. That is
the trade the google-protobuf gem makes: its `FieldDescriptor#get(msg)` sits on the
descriptor, so every pool needs its own copy of every descriptor, and none of it can be
shared between Ractors.

## Why two objects and not one

An analogy from Ruby itself: the descriptor is the `.proto` text turned into data, and
reflection is `Method` and `instance_variable_get`, the runtime handles into live objects.

The reflection verbs could have been singleton methods on the class, since field accessors
live on instances and would not clash. Keeping them on one object is a namespacing choice:
`Klass` keeps a small API of its own (`new`, `decode`, `encode`, `view`, `build`), and
reflection has one place to grow (`Enumerable`, a readable `inspect`, registry and size
queries) without any of those names ever colliding with what a schema might call a field.

## Rules of thumb

- Need a fact about the schema, or something to pass to another Ractor, or something that
  must also hold for the shim's classes: use `descriptor`.
- Need to read or write a field on an instance without knowing its method name, or to find
  the Ruby class behind a field: use `reflection`.
- Writing a tool that walks messages generically (a serializer, a differ, a form builder):
  iterate `reflection.fields` for the shape and call `reflection.get` for the values; the
  descriptor tells you what each value means.
