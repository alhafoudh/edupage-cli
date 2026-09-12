RSpec.describe Edupage::Registry::Context do
  # The chain account > school > student > year must not be skippable. These pin down
  # exactly when a level may be filled in silently and when it has to be refused.
  def account_with(*sessions)
    Edupage::Account.new(
      username: "parent@example.com",
      sessions: sessions,
      credentials: instance_double(Edupage::Credentials),
      cache: Edupage::Cache.new(enabled: false)
    )
  end

  let(:one_school) { account_with(FakeSession.new(origin: "zsdemo")) }
  let(:two_schools) { account_with(FakeSession.new(origin: "zsdemo"), FakeSession.new(origin: "zusdemo")) }

  describe "choosing a school" do
    it "takes the only one without being asked" do
      context = described_class.new(account: one_school)

      expect(context.school.origin).to eq("zsdemo")
    end

    it "refuses to guess between several" do
      context = described_class.new(account: two_schools)

      expect { context.school }.to raise_error(Edupage::AmbiguousScopeError) { |error|
        expect(error.level).to eq(:school)
        expect(error.candidates.map { |c| c[:id] }).to contain_exactly("zsdemo", "zusdemo")
        expect(error.candidates.first[:label]).to eq("Demo School")
      }
    end

    it "accepts an explicit choice" do
      context = described_class.new(account: two_schools, school: "zusdemo")

      expect(context.school.origin).to eq("zusdemo")
    end

    it "does not treat the config default as a choice" do
      # default_school says where to log in, not which school's data to read. Letting it
      # select here is exactly the bug this behaviour exists to prevent.
      Edupage.config["default_school"] = "zsdemo"
      context = described_class.new(account: two_schools)

      expect { context.school }.to raise_error(Edupage::AmbiguousScopeError)
    end

    it "reports an unknown school as missing rather than ambiguous" do
      context = described_class.new(account: two_schools, school: "nosuchschool")

      expect { context.school }.to raise_error(Edupage::NotFoundError, /No school/)
    end
  end

  describe "choosing a student" do
    it "refuses to guess between siblings" do
      context = described_class.new(account: one_school)

      expect { context.student }.to raise_error(Edupage::AmbiguousScopeError) { |error|
        expect(error.level).to eq(:student)
        expect(error.candidates.map { |c| c[:label] })
          .to contain_exactly("Peter Novák, 2.A", "Jana Nováková, 4.A")
      }
    end

    it "accepts a unique prefix" do
      context = described_class.new(account: one_school, student: "Jana")

      expect(context.student.first_name).to eq("Jana")
    end

    it "accepts an id" do
      context = described_class.new(account: one_school, student: "-77")

      expect(context.student.first_name).to eq("Peter")
    end

    it "reports an unknown student as missing" do
      context = described_class.new(account: one_school, student: "Nobody")

      expect { context.student }.to raise_error(Edupage::NotFoundError, /No student/)
    end
  end

  describe "choosing a year" do
    subject(:context) { described_class.new(account: one_school, student: "Jana") }

    it "defaults to the current one and says so" do
      expect(context.year.id).to eq("2026")
      expect(context).to be_year_defaulted
    end

    it "treats an explicit year as chosen" do
      chosen = described_class.new(account: one_school, student: "Jana", year: "2025")

      expect(chosen.year.id).to eq("2025")
      expect(chosen).not_to be_year_defaulted
    end

    it "treats 'current' as the default rather than a choice" do
      chosen = described_class.new(account: one_school, student: "Jana", year: "current")

      expect(chosen.year.id).to eq("2026")
      expect(chosen).to be_year_defaulted
    end
  end

  describe "#receiver_for" do
    it "hands each resource the object its scope names" do
      context = described_class.new(account: one_school, student: "Jana")

      expect(context.receiver_for(Edupage::Registry.fetch(:schools))).to be_a(Edupage::Account)
      expect(context.receiver_for(Edupage::Registry.fetch(:subjects))).to be_a(Edupage::School)
      expect(context.receiver_for(Edupage::Registry.fetch(:homeworks))).to be_a(Edupage::Models::Student)
      expect(context.receiver_for(Edupage::Registry.fetch(:grades))).to be_a(Edupage::Year)
    end
  end
end
