# frozen_string_literal: true

module Protostar
  @generated_pool = Schema::Pool.new

  class << self
    # @return [Schema::Pool] the process-wide pool generated `_pb.rb` files build into
    attr_reader :generated_pool
  end
end
