RSpec.describe Edupage::Parsers::Znamky do
  subject(:document) { described_class.parse(Payloads.znamky_html) }

  it "reads both payloads on the page" do
    expect(document.year_id).to eq("2025")
    expect(document.student_id).to eq("113506")
    expect(document.settings).to include("obdobia")
  end

  it "reports which half-year the response covers" do
    # One request only ever returns one half-year, so this is how a caller knows what
    # it actually got back.
    expect(document.term_id).to eq("P2")
  end

  it "joins a grade to the event that describes it" do
    grade = document.grades.first
    event = document.event_for(grade)

    expect(event["p_meno"]).to eq("Písomka")
    expect(event["priemer"]).to eq("1.50")
  end

  it "returns nil for a grade whose event is missing" do
    orphan = Payloads.grade_row(event: "does-not-exist")

    expect(document.event_for(orphan)).to be_nil
  end

  describe ".path_for" do
    it "asks for a specific half-year when told to" do
      expect(described_class.path_for(term: "P1")).to end_with("nadobdobie=P1")
      expect(described_class.path_for).not_to include("nadobdobie")
    end
  end

  describe "period mapping" do
    it "rolls a sub-period up into its half-year" do
      # A "P2" response contains grades marked P2 and V2 (the end-of-term report);
      # both belong to the second half-year.
      expect(document.parent_period("V2")).to eq("P2")
      expect(document.parent_period("V1")).to eq("P1")
    end

    it "maps a half-year to itself" do
      expect(document.parent_period("P2")).to eq("P2")
    end

    it "passes an unknown period through unchanged" do
      expect(document.parent_period("KL9")).to eq("KL9")
    end
  end

  it "lists every year and term with its grade count" do
    rows = document.year_terms

    expect(rows.map { |r| r["yearid"] }.uniq).to contain_exactly("2025", "2026")
    expect(rows.find { |r| r["yearid"] == "2025" && r["term"] == "P2" }["numGrades"]).to eq("2")
  end

  it "raises when the page is not the grades page" do
    expect { described_class.parse("<html></html>") }
      .to raise_error(Edupage::ParseError, /znamkyStudentViewer/)
  end
end
