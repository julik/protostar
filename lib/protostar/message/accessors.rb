# frozen_string_literal: true

module Protostar
  class Message
    # Writes the field accessors of a message class as Ruby source and evals
    # it into the class. Methods made from source, unlike `define_method`
    # blocks, can be called from any Ractor, and they read their slot by a
    # literal index.
    # @api private
    module Accessors
      module_function

      # Methods every message has; a field whose accessor would replace one
      # is reachable only through `[]` and `[]=`
      def reserved
        (Message.public_instance_methods + %i[initialize]).to_h { |m| [m, true] }
      end

      # @param klass [Class]
      # @param fields [Array<FieldInfo>]
      # @param oneofs [Array<Array(Symbol, Array<Integer>)>] real oneofs: name and member slots
      def install(klass, fields, oneofs)
        taken = reserved
        src = +""
        fields.each do |info|
          name = info.name
          i = info.index
          reader = name.to_sym
          writer = :"#{name}="
          unless taken[reader]
            taken[reader] = true
            src << reader_source(name, info)
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
            src << "def has_#{name}?; !@values[#{i}].nil?; end\n"
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
            src << "  return :#{fields[slot].name} unless @values[#{slot}].nil?\n"
          end
          src << "  nil\nend\n"
        end
        klass.class_eval(src, "(protostar #{klass.descriptor.full_name})", 1)
      end

      def reader_source(name, info)
        i = info.index
        if info.repeated || info.map
          "def #{name}; @values[#{i}] || __container(#{i}); end\n"
        elsif info.message? || !info.presence
          "def #{name}; @values[#{i}]; end\n"
        else
          "def #{name}; v = @values[#{i}]; v.nil? ? #{default_literal(info)} : v; end\n"
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
