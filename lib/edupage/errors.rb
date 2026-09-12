module Edupage
  # Base for everything this library raises on purpose.
  class Error < StandardError; end

  # No usable username/password could be assembled from any provider.
  class MissingCredentialsError < Error; end

  # Edupage rejected the credentials.
  class LoginError < Error; end

  # The login matched several accounts and none was selected.
  class AmbiguousAccountError < LoginError
    attr_reader :candidates

    def initialize(candidates)
      @candidates = candidates
      list = candidates.map { |c| "#{c[:userid]} (#{c[:origin]})" }.join(", ")
      super("Login matches multiple accounts: #{list}. Pass school: to pick one.")
    end
  end

  # The stored session is no longer valid and could not be renewed.
  class SessionExpiredError < Error; end

  # Edupage answered, but not with anything we can read.
  class ParseError < Error
    attr_reader :snippet

    def initialize(message, snippet: nil)
      @snippet = snippet
      super(snippet ? "#{message} (got: #{snippet.to_s[0, 200].inspect})" : message)
    end
  end

  # Transport-level failure that survived the retries in Client.
  class RequestError < Error; end

  # Asked for a school/student/year that this account cannot see.
  class NotFoundError < Error; end

  # A level of the account > school > student > year chain was left unspecified while
  # several options existed.
  #
  # Deliberately not a NotFoundError: "you did not choose" and "it does not exist" are
  # different situations, and the surfaces answer them differently - the CLI lists the
  # options, the REST API answers 400 rather than 404.
  class AmbiguousScopeError < Error
    # level: :school or :student
    # candidates: [{ id:, label: }, ...] - enough for any surface to render a choice
    attr_reader :level, :candidates

    def initialize(level, candidates)
      @level = level
      @candidates = candidates
      super("No #{level} selected; #{candidates.size} to choose from")
    end
  end

  # The keychain provider was asked for something this platform cannot do.
  class UnsupportedPlatformError < Error; end
end
