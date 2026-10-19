# typed: strict

# The parts of google-protobuf's API that protostar's google-format RBI
# names. An application gets these from tapioca (`tapioca gem` for the gem,
# `tapioca dsl` for RepeatedField's and Map's type members).
module Google
  module Protobuf
    module MessageExts
      module ClassMethods; end
    end

    class AbstractMessage
      include MessageExts
      extend MessageExts::ClassMethods
    end

    class Descriptor; end

    class EnumDescriptor; end

    class RepeatedField
      extend T::Generic

      Elem = type_member
    end

    class Map
      extend T::Generic

      Key = type_member
      Value = type_member
    end
  end
end
