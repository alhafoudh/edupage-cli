RSpec.describe Edupage::Models::Grade do
  let(:school) { fake_school }
  let(:term) { Edupage::Models::Term.new({ "term" => "P2", "termName" => "2. polrok" }) }

  def grade(row: {}, event: {})
    described_class.new(
      Payloads.grade_row.merge(row),
      school: school, event: Payloads.event_row.merge(event), term: term
    )
  end

  describe "fields that come from the grade row" do
    it "reads the value and its provenance" do
      subject = grade

      expect(subject.value).to eq("1")
      expect(subject.subject.short).to eq("MAT")
      expect(subject.teacher.short).to eq("Kp")
      expect(subject.student.first_name).to eq("Jana")
      expect(subject.created_at.to_date).to eq(Date.new(2026, 1, 27))
    end

    it "reports whether a parent has signed it" do
      expect(grade).to be_signed_by_parent
      expect(grade(row: { "podpisane_rodic" => nil })).not_to be_signed_by_parent
    end
  end

  describe "fields that come from the event" do
    # The grade row carries almost nothing descriptive; the title, weight and class
    # average all live on the event it points at.
    it "reads the title and the class average" do
      subject = grade(event: { "p_meno" => "Štvrťročná práca", "priemer" => "2.25" })

      expect(subject.title).to eq("Štvrťročná práca")
      expect(subject.class_average).to eq(2.25)
    end

    it "converts Edupage's weight scale, where 20 means 1.0" do
      expect(grade(event: { "p_vaha" => "20" }).weight).to eq(1.0)
      expect(grade(event: { "p_vaha" => "40" }).weight).to eq(2.0)
      expect(grade(event: { "p_vaha" => "10" }).weight).to eq(0.5)
    end

    it "falls back to a weight of 1 when the event does not say" do
      expect(grade(event: { "p_vaha" => nil }).weight).to eq(1.0)
    end

    it "survives a missing event" do
      orphan = described_class.new(Payloads.grade_row, school: school, event: nil)

      expect(orphan.title).to be_nil
      expect(orphan.weight).to eq(1.0)
      expect(orphan.value).to eq("1")
    end
  end

  describe "marks and points" do
    it "recognises a classic mark" do
      subject = grade(event: { "p_typ_udalosti" => "1" })

      expect(subject).to be_mark
      expect(subject).not_to be_points
      expect(subject.percentage).to be_nil
    end

    it "computes a percentage for a points grade" do
      subject = grade(row: { "data" => "18" },
                      event: { "p_typ_udalosti" => "3", "p_vaha_body" => "20" })

      expect(subject).to be_points
      expect(subject.points).to eq(18.0)
      expect(subject.max_points).to eq(20.0)
      expect(subject.percentage).to eq(90.0)
    end

    it "does not divide by a missing maximum" do
      subject = grade(row: { "data" => "18" },
                      event: { "p_typ_udalosti" => "3", "p_vaha_body" => nil })

      expect(subject.percentage).to be_nil
    end
  end

  it "belongs to the half-year it was fetched under" do
    # `mesiac` is the sub-period ("V2" for report marks); the term is the half-year.
    subject = grade(row: { "mesiac" => "V2" })

    expect(subject.period).to eq("V2")
    expect(subject.term.id).to eq("P2")
  end

  it "matches by value, title or subject" do
    subject = grade(event: { "p_meno" => "Písomka" })

    expect(subject.matches?("MAT")).to be(true)
    expect(subject.matches?("Matematika")).to be(true)
    expect(subject.matches?("Písomka")).to be(true)
    expect(subject.matches?("SJL")).to be(false)
  end

  it "serialises the joined view" do
    hash = grade.to_h

    expect(hash).to include(value: "1", title: "Písomka", weight: 1.0, term: "P2")
  end
end
