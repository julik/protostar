# frozen_string_literal: true

module Protostar
  class Message
    # Writes the field accessors of a message class as Ruby source and evals
    # it into the class. Methods made from source, unlike `define_method`
    # blocks, can be called from any Ractor.
    #
    # A field lives in an instance variable named after its slot (`@_0`,
    # `@_1`, ...; FieldInfo#ivar), never after its name, so no field can
    # clash with `@unknown`. `__reset` sets `@unknown` and then every slot in
    # order, and every way of making a message goes through it, so all
    # messages of a class have one object shape, and all classes share one
    # chain of shapes. The by-index methods (`__slot`, `__set_slot`,
    # `__slots`) are for code that walks fields generically.
    module Accessors # :nodoc: all
      module_function

      # Methods every message has; a field whose accessor would replace one
      # is reachable only through `[]` and `[]=`
      def reserved
        (Message.public_instance_methods + %i[initialize]).to_h { |m| [m, true] }
      end

      # - `oneofs`: real oneofs: name and member slots
      # - `reserved`: from `reserved`, computed once for many classes
      #: (Class klass, Array[FieldInfo] fields, Array[[Symbol, Array[Integer]]] oneofs, ?Hash[Symbol, bool] reserved) -> untyped
      def install(klass, fields, oneofs, reserved = self.reserved)
        taken = reserved.dup
        src = slots_source(fields)
        plain = []
        fields.each do |info|
          name = info.name
          i = info.index
          reader = name.to_sym
          writer = :"#{name}="
          unless taken[reader]
            taken[reader] = true
            if plain_reader?(info)
              plain << [reader, i]
            else
              src << reader_source(name, info)
            end
          end
          unless taken[writer]
            taken[writer] = true
            src << "def #{name}=(v); __set(#{i}, v); end\n"
          end
          next unless info.presence
          has = :"has_#{name}?"
          clear = :"clear_#{name}"
          unless taken[has]
            taken[has] = true
            src << "def has_#{name}?; !#{info.ivar}.nil?; end\n"
          end
          unless taken[clear]
            taken[clear] = true
            src << "def clear_#{name}; __clear(#{i}); end\n"
          end
        end
        oneofs.each do |oneof_name, slots|
          which = :"which_#{oneof_name}"
          next if taken[which]
          taken[which] = true
          src << "def which_#{oneof_name}\n"
          slots.each do |slot|
            src << "  return :#{fields[slot].name} unless #{fields[slot].ivar}.nil?\n"
          end
          src << "  nil\nend\n"
        end
        klass.class_eval(src, "(protostar #{klass.descriptor.full_name})", 1)
        define_plain_readers(klass, plain)
      end

      # A reader that returns the variable as it is can be a copy of an
      # `attr_reader`, which YJIT reads inline without a method frame
      def plain_reader?(info)
        !(info.repeated || info.map) && (info.message? || !info.presence)
      end

      # The `attr_reader`s are made in a scratch module under their slot
      # names, so a field called `_3` cannot get in the way
      def define_plain_readers(klass, plain)
        return if plain.empty?
        scratch = Module.new
        scratch.send(:attr_reader, *plain.map { |_, i| :"_#{i}" })
        plain.each { |name, i| klass.define_method(name, scratch.instance_method(:"_#{i}")) }
      end

      def reader_source(name, info)
        iv = info.ivar
        if info.repeated || info.map
          "def #{name}; #{iv} || __container(#{info.index}); end\n"
        else
          "def #{name}; v = #{iv}; v.nil? ? #{default_literal(info)} : v; end\n"
        end
      end

      # `Klass.__empty`, `__reset`, `__load_slots`, `__slot`, `__set_slot`,
      # `__slots`, `__copy_slots` and `__freeze_slots`
      def slots_source(fields)
        ivars = fields.map(&:ivar)
        src = +"# frozen_string_literal: true\n"
        # one per class, so YJIT sees one receiver at each call inside
        src << "def self.__empty\nallocate.__reset\nend\n"
        defaults = fields.map { |f| literal(f.index, (f.presence || f.repeated || f.map) ? nil : f.default) }
        src << "def __reset\n"
        src << "t = self.class.__template\n" if defaults.any? { |d| d.start_with?("t[") }
        src << "@unknown = nil\n"
        ivars.each_with_index { |iv, i| src << "#{iv} = #{defaults[i]}\n" }
        src << "self\nend\n"
        src << "def __load_slots(a)\n@unknown = nil\n"
        ivars.each_with_index { |iv, i| src << "#{iv} = a[#{i}]\n" }
        src << "self\nend\n"
        src << "def __slots\n[#{ivars.join(", ")}]\nend\n"
        if fields.empty?
          src << "def __slot(_)\nnil\nend\ndef __set_slot(_, v)\nv\nend\n"
        else
          src << "def __slot(i)\ncase i\n"
          ivars.each_with_index { |iv, i| src << "when #{i} then #{iv}\n" }
          src << "end\nend\n"
          src << "def __set_slot(i, v)\ncase i\n"
          ivars.each_with_index { |iv, i| src << "when #{i} then #{iv} = v\n" }
          src << "else raise IndexError, \"no slot \#{i}\"\nend\nend\n"
        end
        src << "def __copy_slots\n"
        fields.each do |f|
          next unless f.repeated || f.map || f.message?
          src << "#{f.ivar} = Protostar::Message.__copy_value(#{f.ivar}) unless #{f.ivar}.nil?\n"
        end
        src << "@unknown = @unknown&.dup&.freeze\nend\n"
        src << "def __freeze_slots\n"
        fields.each { |f| src << freeze_source(f) }
        src << "@unknown&.freeze\nend\n"
      end

      def freeze_source(f)
        iv = f.ivar
        if f.map
          deep = f.value.message? || f.value.kind == FieldInfo::STRING || f.value.kind == FieldInfo::BYTES
          "#{iv}&.#{"each_value(&:freeze)&." if deep}freeze\n"
        elsif f.repeated
          deep = f.message? || f.kind == FieldInfo::STRING || f.kind == FieldInfo::BYTES
          "#{iv}&.#{"each(&:freeze)&." if deep}freeze\n"
        elsif f.message?
          "#{iv}&.freeze\n"
        else
          ""
        end
      end

      # A value as a literal when it has an exact one, otherwise read from
      # the class's template
      def literal(index, value)
        case value
        when Integer, true, false, nil, Symbol then value.inspect
        when Float then value.finite? ? value.inspect : "t[#{index}]"
        else "t[#{index}]"
        end
      end

      # The default as a literal when it has an exact one, otherwise a lookup
      def default_literal(info)
        d = info.default
        case d
        when Integer, true, false, Symbol then d.inspect
        when Float then d.finite? ? d.inspect : "self.class.__fields[#{info.index}].default"
        else "self.class.__fields[#{info.index}].default"
        end
      end
    end
  end
end
