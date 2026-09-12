RSpec.describe Edupage::Models::Assignment do
  let(:school) { fake_school }

  def assignment(**options)
    described_class.new(Payloads.homework_item(**options), school: school)
  end

  # The reason this model exists: Edupage announces homework in two shapes, and the
  # upstream JS library only ever builds objects from the class-wide one. On the account
  # this was written against that loses 15 of 16 tasks for one child.
  describe "the two shapes of an assignment" do
    let(:personal) do
      assignment(id: "1", recipient: "Student113506", title: "PZ str.3", due: "2026-09-14")
    end
    let(:class_wide) do
      assignment(id: "2", recipient: "CustPlan8562", title: "Čítanka str.6", due: "2026-09-15")
    end

    it "reads a task set to one pupil" do
      expect(personal.title).to eq("PZ str.3")
      expect(personal.due_on).to eq(Date.new(2026, 9, 14))
      expect(personal.subject.short).to eq("SJL")
      expect(personal).not_to be_class_wide
      expect(personal.recipient.first_name).to eq("Jana")
    end

    it "reads a task set to a whole class" do
      expect(class_wide.title).to eq("Čítanka str.6")
      expect(class_wide.due_on).to eq(Date.new(2026, 9, 15))
      expect(class_wide).to be_class_wide
    end

    it "gives both the same interface" do
      %i[title due_on subject assigned_on class_wide? homework?].each do |message|
        expect { personal.public_send(message) }.not_to raise_error
        expect { class_wide.public_send(message) }.not_to raise_error
      end
    end
  end

  describe "types" do
    it "treats a plain homework item as homework" do
      expect(assignment(id: "1", recipient: "Student113506", title: "x")).to be_homework
    end

    it "reads an explicit type from the payload" do
      row = Payloads.homework_item(id: "1", recipient: "Student113506", title: "x")
      row["data"] = JSON.generate(JSON.parse(row["data"]).merge("typ" => "test"))

      expect(described_class.new(row, school: school)).to be_test
    end

    it "takes the first of a pipe-separated etype" do
      row = Payloads.homework_item(id: "1", recipient: "Student113506", title: "x")
      row["data"] = JSON.generate(JSON.parse(row["data"]).merge("etype" => "etesthw|hw"))

      expect(described_class.new(row, school: school).type).to eq("etesthw")
    end
  end

  describe ".assignment?" do
    it "accepts the timeline types that carry work" do
      expect(described_class.assignment?("typ" => "homework")).to be(true)
      expect(described_class.assignment?("typ" => "testpridelenie")).to be(true)
    end

    it "rejects everything else" do
      expect(described_class.assignment?("typ" => "sprava")).to be(false)
      expect(described_class.assignment?("typ" => "stravamenu")).to be(false)
    end
  end

  it "knows when a task is past its date" do
    past = assignment(id: "1", recipient: "Student113506", title: "x", due: "2000-01-01")
    future = assignment(id: "2", recipient: "Student113506", title: "y", due: "2999-01-01")

    expect(past).to be_overdue
    expect(future).not_to be_overdue
  end

  it "matches by title or subject" do
    subject = assignment(id: "1", recipient: "Student113506", title: "Čítanka str.6")

    expect(subject.matches?("SJL")).to be(true)
    expect(subject.matches?("Čítanka str.6")).to be(true)
    expect(subject.matches?(/čítanka/i)).to be(true)
  end

  it "serialises without leaking raw Edupage keys" do
    hash = assignment(id: "1", recipient: "Student113506", title: "PZ str.3").to_h

    expect(hash).to include(title: "PZ str.3", type: "hw", class_wide: false)
    expect(hash.keys).not_to include(:nazov, :predmetid)
  end

  it "tolerates a payload that is not JSON" do
    row = Payloads.homework_item(id: "1", recipient: "Student113506", title: "x")
    row["data"] = "not json at all"

    subject = described_class.new(row, school: school)

    expect(subject.title).to be_nil
    expect(subject.due_on).to be_nil
  end
end
