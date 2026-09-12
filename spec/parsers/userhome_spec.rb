RSpec.describe Edupage::Parsers::Userhome do
  subject(:document) { described_class.parse(Payloads.userhome_html) }

  it "reads the three payloads the page carries" do
    expect(document.data).to include("dbi", "dp", "items")
    expect(document.edubar).to include("selectedYear")
    expect(document.asc).to include("gsechash")
  end

  it "exposes the school's identity" do
    expect(document.school_name).to eq("Demo School")
    expect(document.origin).to eq("zsdemo")
    expect(document.gsec_hash).to eq("abc12345")
    expect(document.language).to eq("sk")
  end

  it "distinguishes the selected year from the real one" do
    # selectedYear follows the session cursor; autoYear does not, which is what makes
    # it usable as the anchor when the cursor was left somewhere else.
    document = described_class.parse(Payloads.userhome_html(year: "2025"))

    expect(document.selected_year).to eq("2025")
    expect(document.current_year).to eq("2026")
  end

  it "reports which child the session is pointed at" do
    expect(described_class.parse(Payloads.userhome_html(child: "-77")).logged_child).to eq("-77")
  end

  it "normalises dbi collections whether keyed or listed" do
    expect(document.collection("students").size).to eq(3)
    # periods arrive as an array while the rest are hashes keyed by id
    expect(document.collection("periods").size).to eq(2)
    expect(document.collection("nonexistent")).to eq([])
  end

  it "lists the account's own children" do
    expect(document.parent_student_ids).to eq(%w[-77 113506])
  end

  it "maps children to the userstrings that stand for them" do
    expect(document.child_groups["113506"]).to include("Student113506", "CustPlan8562")
  end

  it "exposes the days of the timetable" do
    expect(document.dates.keys).to eq([Date.today.iso8601])
  end

  it "raises a clear error when the page is not a dashboard" do
    expect { described_class.parse("<html>login form</html>") }
      .to raise_error(Edupage::ParseError, /Could not find \.userhome/)
  end
end
