# frozen_string_literal: true

module Protostar
  # Extended by every enum Module that {Types.define} makes. Such a Module has
  # one constant per value (aliases included) holding its number, and is frozen.
  #
  #   Color::RED          # => 1
  #   Color.lookup(1)     # => :RED
  #   Color.resolve(:RED) # => 1
  module Enum
    # @return [Schema::Enum]
    attr_reader :descriptor

    # @param number [Integer]
    # @return [Symbol, nil] the first name declared for the number
    def lookup(number)
      @__names[number]
    end

    # @param name [Symbol, String]
    # @return [Integer, nil]
    def resolve(name)
      @__numbers[name.is_a?(String) ? name.to_sym : name]
    end

    # @api private
    def __names
      @__names
    end

    # @api private
    def __numbers
      @__numbers
    end

    def inspect
      name || "#<Module #{@descriptor.full_name}>"
    end

    # Builds the enum Module for a descriptor
    # @param descriptor [Schema::Enum]
    # @return [Module] frozen
    # @api private
    def self.build(descriptor)
      mod = Module.new
      mod.extend(self)
      names = {}
      numbers = {}
      descriptor.values.each do |v|
        sym = v.name.to_sym
        names[v.number] ||= sym
        numbers[sym] = v.number
        const = constant_name(v.name)
        mod.const_set(const, v.number) if const && !mod.const_defined?(const, false)
      end
      mod.instance_variable_set(:@descriptor, descriptor)
      mod.instance_variable_set(:@__names, Ractor.make_shareable(names))
      mod.instance_variable_set(:@__numbers, Ractor.make_shareable(numbers))
      mod
    end

    # @return [String, nil] the value name as a Ruby constant name: first
    #   letter upper-cased, nil when that is still not a constant name
    # @api private
    def self.constant_name(name)
      const = name.sub(/\A[a-z]/, &:upcase)
      const if /\A[A-Z]\w*\z/.match?(const)
    end
  end
end
