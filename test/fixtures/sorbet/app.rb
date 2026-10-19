# typed: strict
# frozen_string_literal: true

# Uses the classes compiled from shop.proto the way an application would.
# Sorbet must report exactly three things here: the revealed type, the typo
# and the Integer given for a String field.
class Checkout
  extend T::Sig

  sig { params(email: String, skus: T::Array[String]).returns(Shop::Order) }
  def self.place(email, skus)
    order = Shop::Order.new(
      customer_email: email,
      items: skus.map { |sku| Shop::LineItem.new(sku: sku, quantity: 1) },
      status: :STATUS_PLACED,
      placed_at: Time.now
    )
    order.items << Shop::LineItem.new(sku: "gift-wrap")
    order.id = "o-1"
    order
  end

  sig { params(bytes: String).returns(String) }
  def self.email_of(bytes)
    order = Shop::Order.decode(bytes)
    T.reveal_type(order)
    placed = order.placed_at&.to_time
    count = order.items.sum(&:quantity)
    "#{order.customer_email} #{placed} #{count} #{Shop::Status::STATUS_PLACED} #{order.encode.bytesize}"
  end

  sig { params(order: Shop::Order).returns(String) }
  def self.typo(order)
    order.custmer_email
  end

  sig { params(order: Shop::Order).void }
  def self.wrong_type(order)
    order.id = 42
  end
end
