module Edupage
  module Models
    # A guardian. dbi lists every pupil's parents, not only the account's own.
    class Parent < Person
      USER_STRING_PREFIX = "Rodic".freeze
    end
  end
end
