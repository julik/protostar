# frozen_string_literal: true

module Protostar
  class Builder
    # Makes the builder class for a message class. The builder writes
    # nested messages with the same object, so it needs a method for every
    # field name of every message reachable from the root; each method
    # dispatches on the index of the message being written (`@k`) with a
    # literal `case`, the way the codec's generated methods do, and is
    # compiled from source so that it runs in any Ractor.
    module Generator # :nodoc: all
      module_function

      # - `root`: a message class
      #
      # Returns a frozen subclass of Builder.
      #: (singleton(Message) root) -> singleton(Builder)
      def generate(root)
        classes = reachable(root)
        index = classes.each_with_index.to_h.compare_by_identity
        by_name = Hash.new { |h, k| h[k] = [] }
        classes.each_with_index do |klass, i|
          klass.__fields.each { |f| by_name[f.name] << [i, f] }
        end

        builder = Class.new(Builder) #: singleton(Builder)
        builder.const_set(:CLASSES, Ractor.make_shareable(classes))
        builder.const_set(:INDEX, Ractor.make_shareable(index))
        builder.const_set(:BY_NAME, Ractor.make_shareable(classes.map(&:__by_name)))
        src = +"# frozen_string_literal: true\n"
        by_name.each do |name, entries|
          next if reserved?(name)
          entries.each { |i, f| builder.const_set(:"F#{i}_#{f.index}", f) }
          src << field_method(name, entries)
        end
        builder.class_eval(src, "(protostar builder #{root.descriptor.full_name})", 1)
        builder.singleton_class.class_eval("def inspect = #{"#<Class Protostar::Builder(#{root.descriptor.full_name})>".inspect}", __FILE__, __LINE__)
        builder.freeze
      end

      # Message classes reachable from `root` through message fields and map values, `root` first
      def reachable(root)
        seen = {}.compare_by_identity
        queue = [root]
        until queue.empty?
          klass = queue.shift
          next if seen.key?(klass)
          seen[klass] = true
          klass.__fields.each do |f|
            child = f.map ? f.value.message_class : f.message_class
            queue << child if child && !seen.key?(child)
          end
        end
        seen.keys
      end

      # Names that would replace a method every object or every builder needs
      def reserved?(name)
        Builder.method_defined?(name) || Builder.private_method_defined?(name)
      end

      def field_method(name, entries)
        src = "def #{name}(value = NONE, &block)\ncase @k\n"
        entries.each do |i, f|
          c = "F#{i}_#{f.index}"
          src << "when #{i} then (block_given? || NONE.equal?(value)) ? __set(#{c}, value, EMPTY, &block) : __put(#{c}, value)\n"
        end
        src << "else __no_field(#{name.inspect})\nend\nself\nend\n"
      end
    end
  end
end
