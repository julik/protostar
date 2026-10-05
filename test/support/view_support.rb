# frozen_string_literal: true

# Helpers for the view tests
module ViewSupport
  module_function

  # The value with every NaN replaced by a Symbol, so that `==` on Hashes
  # and Arrays treats NaN as equal to itself, as Message#== does
  def plain(value)
    case value
    when Hash then value.to_h { |k, v| [plain(k), plain(v)] }
    when Array then value.map { |v| plain(v) }
    when Float then value.nan? ? :nan : value
    else value
    end
  end

  # A message encoded field by field by hand
  def wire
    Protostar::Wire::Writer.new
  end
end
