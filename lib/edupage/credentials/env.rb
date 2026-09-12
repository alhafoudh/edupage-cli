module Edupage
  class Credentials
    # Highest-priority provider: plain environment variables.
    class Env
      VARS = {
        username: "EDUPAGE_USERNAME",
        password: "EDUPAGE_PASSWORD",
        school: "EDUPAGE_SCHOOL"
      }.freeze

      def initialize(env = ENV)
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
