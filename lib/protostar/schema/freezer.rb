# frozen_string_literal: true

module Protostar
  module Schema
    # Deep-copies plain data (Hashes, Arrays, Strings, scalars) into frozen,
    # deduplicated form so that building never freezes the caller's input.
    # @api private
    module Freezer
      EMPTY_HASH = {}.freeze
      EMPTY_ARRAY = [].freeze

      # Freezes a descriptor graph before `Ractor.make_shareable` sees it.
      # make_shareable on a graph full of back-references (every field points
      # at its message, which points at all its fields) re-checks the graph
      # from each back-reference and goes quadratic: about 1.4s for
      # unittest.proto. Freezing everything first lets it confirm the graph in
      # one pass. Arrays and Hashes are always descended into, since they may
      # be frozen while their members are not; other frozen objects are
      # finished descriptors of dependencies or immutable values.
      def self.deep_freeze(root)
        stack = [root]
        containers = {}.compare_by_identity
        until stack.empty?
          obj = stack.pop
          case obj
          when Array
            next if containers.key?(obj)
            containers[obj] = true
            stack.concat(obj)
          when Hash
            next if containers.key?(obj)
            containers[obj] = true
            obj.each { |k, v| stack << k << v }
          else
            next if obj.frozen?
            obj.instance_variables.each { |ivar| stack << obj.instance_variable_get(ivar) }
          end
          obj.freeze
        end
        root
      end

      def self.call(value)
        case value
        when Hash
          return EMPTY_HASH if value.empty?
          value.each_with_object({}) { |(k, v), out| out[call(k)] = call(v) }.freeze
        when Array
          return EMPTY_ARRAY if value.empty?
          value.map { |v| call(v) }.freeze
        when String
          -value
        when Symbol, Integer, Float, true, false, nil
          value
        else
          raise Error, "cannot store a #{value.class} in a descriptor: #{value.inspect}"
        end
      end
    end
  end
end
