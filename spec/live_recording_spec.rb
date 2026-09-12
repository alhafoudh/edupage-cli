require "edupage"

# Records a cassette against the real account and proves nothing personal survived.
#
# Excluded from the normal run; it needs credentials and a network:
#
#   EDUPAGE_LIVE_USERNAME=you@example.com EDUPAGE_LIVE_SCHOOL=yourschool \
#     bundle exec rspec spec/live_recording_spec.rb --tag live
#
# The list of things that must not appear is read off the live account rather than
# written here by hand. A hand-written list only ever proves that the names someone
# thought of are gone - this one fails the moment a classmate, a teacher or a second
# school turns up that the scrubber does not know how to find.
RSpec.describe "recording a cassette", :live do
  let(:username) { ENV.fetch("EDUPAGE_LIVE_USERNAME") }
  let(:school) { ENV.fetch("EDUPAGE_LIVE_SCHOOL") }
  let(:password) { Edupage::Credentials::Keychain.new.password(username: username) }
  let(:cassette) { File.join(VCR.configuration.cassette_library_dir, "live_smoke.yml") }

  # Room and building labels are neither people nor schools, and blanking them would
  # leave a timetable cassette meaningless.
  let(:not_personal) { %w[Základná Stredná Umelecká škola] }

  it "writes no real person, school or session id to disk" do
    expected = live_values

    VCR.use_cassette("live_smoke", record: :all) do
      users = Edupage::Client.mauth(school: school, username: username, password: password)
      entry = users.find { |user| user[:origin] == school }
      Edupage::Client.new(origin: entry[:origin], session_id: entry[:session_id]).get("/user/")
    end

    recorded = File.read(cassette, encoding: Encoding::UTF_8)

    # The dashboard is served gzipped; a compressed body would pass every check below
    # while still holding every name, so confirm it was stored as readable text.
    expect(recorded).to include(".userhome("), "the cassette holds no readable dashboard"

    leaked = expected.select { |value| recorded.match?(/(?<![[:alpha:]])#{Regexp.escape(value)}(?![[:alpha:]])/i) }

    expect(leaked).to be_empty, "leaked from the live account: #{leaked.join(", ")}"
    expect(recorded).not_to include(password)
  end

  # Every name and identifier the account can actually see.
  #
  # Gathered with VCR stood down: this is the reference list, so it has to come from
  # the live account rather than from whatever a cassette happens to hold.
  def live_values
    VCR.turned_off(ignore_cassettes: true) do
      WebMock.allow_net_connect!
      begin
        gather_live_values
      ensure
        WebMock.disable_net_connect!(allow_localhost: false)
        Edupage.reset!
      end
    end
  end

  def gather_live_values
    account = Edupage.account(username: username, school: school)
    values = account.schools.flat_map { |s| [s.origin, *s.name.split(/[\s,.-]+/)] }

    directory = account.school(school)
    %i[students teachers parents].each do |collection|
      directory.public_send(collection).each { |person| values << person.first_name << person.last_name }
    end

    values.compact.map(&:strip).uniq
          .select { |value| value.length >= 4 }
          .reject { |value| not_personal.include?(value) }
  end
end
