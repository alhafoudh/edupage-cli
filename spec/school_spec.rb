RSpec.describe Edupage::School do
  subject(:school) { fake_school }

  describe "the directory" do
    it "reads every collection from one dashboard fetch" do
      school.teachers
      school.classes
      school.subjects
      school.periods

      expect(school.session.requests.count { |path| path.start_with?("/user/") }).to eq(1)
    end

    it "narrows students to the account's own children for a parent" do
      # dbi lists every pupil in the school; a parent only means their own.
      expect(school.students.map(&:first_name)).to contain_exactly("Peter", "Jana")
    end

    it "still resolves a classmate by id" do
      expect(school.student("999").first_name).to eq("Iný")
    end

    it "resolves references between records" do
      jana = school.students.find_by(name: /Jana/)

      expect(jana.school_class.name).to eq("4.A")
      expect(jana.school_class.teacher.short).to eq("Kp")
      expect(jana.parents.map(&:first_name)).to eq(["Ahmed"])
    end
  end

  describe "#resolve_user_string" do
    it "understands the typed ids Edupage uses in the timeline" do
      expect(school.resolve_user_string("Student113506").first_name).to eq("Jana")
      expect(school.resolve_user_string("Ucitel37135").short).to eq("Gl")
      expect(school.resolve_user_string("Rodic-1").first_name).to eq("Ahmed")
    end

    it "treats StudentOnly as Student" do
      expect(school.resolve_user_string("StudentOnly113506").first_name).to eq("Jana")
    end

    it "returns nil for group and wildcard recipients" do
      expect(school.resolve_user_string("CustPlan8562")).to be_nil
      expect(school.resolve_user_string("*")).to be_nil
      expect(school.resolve_user_string(nil)).to be_nil
    end
  end

  describe "cursors" do
    it "asks for the child a timetable belongs to" do
      peter = school.students.find_by(name: /Peter/)
      school.timetable_for(peter)

      expect(school.session.child).to eq("-77")
    end

    it "pins the year rather than trusting whatever the session was left on" do
      # A previous process may have left the cursor in the past; the current year is
      # read from autoYear, which the cursor does not affect.
      session = FakeSession.new(year: "2023")
      school = described_class.new(session, cache: Edupage::Cache.new(enabled: false))

      school.students

      expect(school.current_year).to eq("2026")
      expect(session.year).to eq("2026")
    end

    it "refetches until the page catches up with a switch" do
      # The real server acknowledges a switch immediately but serves the previous
      # child or year for another request or two.
      school = fake_school(lag: 2, child: "-77")

      jana = school.students.find_by(name: /Jana/)
      day = school.timetable_for(jana)

      expect(day).not_to be_nil
      expect(school.session.child).to eq("113506")
    end

    it "refuses rather than returning another child's data when it never catches up" do
      # Starts on Peter, so reading Jana's timetable genuinely requires a switch.
      school = fake_school(lag: 99, child: "-77")
      jana = school.students.find_by(name: /Jana/)

      expect { school.timetable_for(jana) }
        .to raise_error(Edupage::NotFoundError, /never returned dashboard/)
    end
  end

  describe "years" do
    it "lists them from a single fetch" do
      jana = school.students.find_by(name: /Jana/)
      before = school.session.requests.size

      years = school.years_for(jana)

      expect(years.map(&:id)).to eq(%w[2026 2025])
      # One grades page, not one per year.
      expect(school.session.requests.size - before).to be <= 2
    end

    it "marks the current one" do
      jana = school.students.find_by(name: /Jana/)

      expect(school.years_for(jana).find(&:current?).id).to eq("2026")
    end
  end
end
