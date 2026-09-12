module Edupage
  module Models
    # A room. Edupage also models floors and buildings as classrooms, which is why
    # some entries are hidden from the class book.
    class Classroom < Model
      attribute :name
      attribute :short
      attribute :hidden_in_classbook, "cb_hidden", cast: :boolean

      alias hidden_in_classbook? hidden_in_classbook
    end
  end
end
