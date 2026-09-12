module Edupage
  module Models
    # A taught subject, e.g. "Slovenský jazyk a literatúra" (SJL).
    class Subject < Model
      attribute :name
      attribute :short
    end
  end
end
