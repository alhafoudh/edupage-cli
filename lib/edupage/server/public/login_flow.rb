require "uri"

module Edupage
  module Server
    module Public
      # What happens between "the user typed their Edupage login" and "the client gets
      # an authorization code": the password check, then two-factor approval for every
      # school that asks for it, then the grant.
      class LoginFlow
        class Blocked < StandardError; end
        class BadCredentials < StandardError; end
        class NothingUsable < StandardError; end
        class InvalidSchool < StandardError; end
        # The login already produced its grant (double submit, a second poll racing).
        class Finished < StandardError; end

        def initialize(pending:, rate_limiter:, grants:, issuer:,
                       mauth: ->(**args) { Client.mauth(**args) },
                       web_login: ->(**args) { WebLogin.new(**args) })
          @pending = pending
          @rate_limiter = rate_limiter
          @grants = grants
          @issuer = issuer
          @mauth = mauth
          @web_login = web_login
        end

        # A school is the subdomain in <school>.edupage.org; anything else would make the
        # server talk to a host of the visitor's choosing.
        SCHOOL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

        # :two_factor when at least one school needs a second factor, :done otherwise.
        def submit_password(auth, school:, username:, password:, ip:)
          school = school.to_s.strip.downcase.delete_suffix(".edupage.org")
          raise InvalidSchool unless school.match?(SCHOOL)

          username = username.to_s.strip
          keys = [ip.to_s, "#{username.downcase}|#{school}"]
          raise Blocked if @rate_limiter.blocked?(*keys)

          # Only a rejected password counts towards the lockout; an Edupage outage
          # propagates as itself.
          entries = begin
            @mauth.call(school: school, username: username, password: password.to_s)
          rescue BadCredentialsError
            @rate_limiter.failure!(*keys)
            raise BadCredentials
          end
          @rate_limiter.reset!(*keys)

          auth.synchronize do
            # The password stays on the pending login, in memory, until the grant exists.
            auth.password = password.to_s
            auth.credentials = { username: username, school: school, schools: entries.map { |e| e[:origin] } }
            auth.sessions = entries.reject { |e| e[:needs_2fa] }.to_h { |e| [e[:origin], e] }
            auth.queue = entries.select { |e| e[:needs_2fa] }.map { |e| e[:origin] }
            auth.two_factor_total = auth.queue.size
            auth.skipped = []
            auth.current = auth.info = nil
            auth.queue.empty? ? :done : :two_factor
          end
        end

        # The school waiting for approval, or nil when none is left.
        def current_school(auth) = auth.queue.first

        # [school, its position, how many schools ask for a second factor].
        def progress(auth)
          total = auth.two_factor_total.to_i
          [auth.queue.first, total - auth.queue.size + 1, total]
        end

        # Starts the web login of the next 2FA school on first use. When Edupage has no
        # device to push to, the e-mail goes out right away.
        def current_two_factor(auth)
          auth.synchronize do
            return nil if auth.queue.empty?
            return auth.info if auth.info

            creds = auth.credentials
            auth.current = @web_login.call(school: auth.queue.first, username: creds[:username],
                                           password: auth.password)
            result = auth.current.start
            if result.status == :ok
              accept(auth, result)
              return current_two_factor(auth)
            end

            auth.info = auth.current.two_factor_info
            auth.current.send_email if auth.info.channel == :email
            auth.info
          end
        end

        # :waiting, :expired, or :next / :done once approved.
        def poll(auth)
          auth.synchronize do
            current_two_factor(auth) or return :done
            answer = auth.current.poll
            return answer if answer.is_a?(Symbol)

            accept(auth, auth.current.complete(answer))
          end
        end

        # :next / :done, or :invalid for a wrong code.
        def submit_code(auth, code)
          auth.synchronize do
            current_two_factor(auth) or return :done
            accept(auth, auth.current.complete(code.to_s.strip))
          rescue LoginError
            :invalid
          end
        end

        def send_email(auth)
          auth.synchronize { current_two_factor(auth) && auth.current.send_email }
        end

        def resend_push(auth)
          auth.synchronize { current_two_factor(auth) && auth.current.resend_push }
        end

        def skip(auth)
          auth.synchronize do
            auth.skipped << auth.queue.shift if auth.queue.any?
            auth.current = auth.info = nil
            auth.queue.empty? ? :done : :next
          end
        end

        # Issues the grant and returns where to send the browser.
        def finish(auth)
          auth.synchronize do
            raise Finished unless @pending.find(auth.id).equal?(auth)
            raise NothingUsable if auth.credentials.nil? || auth.sessions.empty?

            oauth = auth.oauth
            # Sessions only: the password is never handed to the grant.
            credentials = auth.credentials.merge(two_factor_origins: auth.skipped.dup, sessions: stored_sessions(auth))
            _grant_id, code = @grants.issue_code(
              client_id: oauth[:client_id], credentials: credentials, redirect_uri: oauth[:redirect_uri],
              code_challenge: oauth[:code_challenge], resource: oauth[:resource]
            )
            auth.password = nil
            @pending.delete(auth.id)
            redirect(oauth[:redirect_uri], "code" => code, "state" => oauth[:state], "iss" => @issuer)
          end
        end

        def redirect(base, params)
          uri = URI(base)
          query = URI.decode_www_form(uri.query.to_s) + params.compact.to_a
          uri.query = URI.encode_www_form(query)
          uri.to_s
        end

        private

        # What the grant keeps per school: enough to rebuild a Session, nothing more.
        def stored_sessions(auth)
          auth.sessions.to_h do |origin, entry|
            name = entry[:name] || [entry[:first_name], entry[:last_name]].compact.join(" ")
            [origin, { session_id: entry[:session_id], userid: entry[:userid], role: entry[:role], name: name }]
          end
        end

        def accept(auth, result)
          origin = auth.queue.shift
          auth.sessions[origin] = {
            origin: origin, session_id: result.session_id, userid: result.userid, role: result.role,
            first_name: result.name, last_name: nil, needs_2fa: false
          }
          auth.current = auth.info = nil
          auth.queue.empty? ? :done : :next
        end
      end
    end
  end
end
