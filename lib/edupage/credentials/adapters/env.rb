module Edupage
  class Credentials
    module Adapters
      # Highest-priority source: plain environment variables. Whatever it supplies wins,
      # and nothing after it is consulted for that field.
      class Env < Adapter
        VARS = {
          username: "EDUPAGE_USERNAME",
          password: "EDUPAGE_PASSWORD",
          school: "EDUPAGE_SCHOOL"
        }.freeze

        class << self
          def available? = true
          def display_name = "environment"
        end

        def initialize(env = ENV)
          super()
          @env = env
        end

        def username(**) = @env[VARS[:username]]
        def password(**) = @env[VARS[:password]]

        # Accepts either "zsdemo" or "zsdemo.edupage.org".
        def school(**)
          value = @env[VARS[:school]]
          value&.sub(/\.edupage\.org\z/, "")
        end

        def source_for(field) = "ENV: #{VARS[field]}"
      end
    end
  end
end
