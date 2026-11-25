module Edupage
  # Credentials handed over directly instead of resolved from env, keychain or config.
  #
  # The public server decrypts a grant's login for the length of a request and needs
  # something Account and Session accept in place of Credentials, without ever touching
  # this machine's own credential sources.
  class StaticCredentials
    attr_reader :username, :school

    # password: nil means a login that must not be repeated: the public server keeps
    # only sessions, and an expired one ends the connection instead of logging in again.
    def initialize(username:, password:, school:)
      @username = username
      @password = password
      @school = school
    end

    def password
      @password or raise SessionExpiredError, "The Edupage session expired and no password is kept"
    end

    def to_h
      { username: username, school: school }
    end

    # Never let a password reach a log line, a backtrace or `p`.
    def inspect = "#<Edupage::StaticCredentials username=#{username.inspect}>"
    alias to_s inspect
  end
end
