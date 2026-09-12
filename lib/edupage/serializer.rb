module Edupage
  # Turns whatever a resolver returned into plain JSON-ready data.
  #
  # Every surface goes through here, so `edupage grades --json`, the REST response and
  # the MCP tool result are the same bytes. Models decide their own shape in #to_h;
  # this only deals with collections, dates and stray objects.
  module Serializer
    module_function

    def call(result)
      case result
      when Relation, Array then result.map { |item| one(item) }
      else one(result)
      end
    end

    def one(object)
      case object
      when nil then nil
      when Hash then object.transform_keys(&:to_sym).transform_values { |v| one(v) }
      when Array then object.map { |item| one(item) }
      when Date, Time then object.iso8601
      when String, Numeric, TrueClass, FalseClass then object
      else
        object.respond_to?(:to_h) ? one(object.to_h) : object.to_s
      end
    end

    # Value for one column of a table, addressed by method name. Predicate names are
    # allowed so table_fields can say :class_wide? without a shadow accessor.
    def field(object, name)
      return nil unless object.respond_to?(name)

      display(object.public_send(name))
    end

    def header(name) = name.to_s.delete_suffix("?").tr("_", " ")

    def display(value)
      case value
      when nil then ""
      when true then "yes"
      when false then "no"
      when Date then value.iso8601
      when Time then value.strftime("%Y-%m-%d %H:%M")
      when Array then value.map { |v| display(v) }.reject(&:empty?).join(", ")
      when Relation then display(value.to_a)
      when Model then value.name.to_s
      else value.to_s
      end
    end
  end
end
