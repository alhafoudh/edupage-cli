module Edupage
  class Credentials
    # Common interface of every credential source.
    #
    # Credentials asks adapters in a fixed order and stops at the first value, so an
    # adapter only ever runs when every adapter before it came up empty. A source that
    # does not hold a field just returns nil for it.
    class Adapter
      class << self
        def available?
          raise NotImplementedError, "#{name}.available? is not implemented"
        end

        def display_name
          raise NotImplementedError, "#{name}.display_name is not implemented"
        end
      end

      def display_name = self.class.display_name

      def username(**) = nil
      def school(**) = nil
      def password(**) = nil

      # Whether `edupage login` can store a password here.
      def writable? = false

      # Label shown by `edupage auth` next to a value this adapter supplied.
      def source_for(_field)
        raise NotImplementedError, "#{self.class.name}#source_for is not implemented"
      end
    end
  end
end
