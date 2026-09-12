RSpec.describe Edupage::Parsers::Timeline do
  let(:items) do
    [
      Payloads.homework_item(id: "1", recipient: "Student113506", title: "Jana personal"),
      Payloads.homework_item(id: "2", recipient: "CustPlan8562", title: "4.A class-wide"),
      Payloads.homework_item(id: "3", recipient: "Student-77", title: "Peter personal"),
      Payloads.homework_item(id: "4", recipient: "CustPlan8503", title: "2.A class-wide"),
      Payloads.message_item(id: "5", recipient: "*", text: "Whole school")
    ]
  end

  subject(:timeline) do
    described_class.parse({ "items" => items },
                          child_groups: Payloads.userhome["childGroups"])
  end

  it "keeps the feed whole" do
    expect(timeline.items.size).to eq(5)
  end

  describe "attributing a shared feed to a child" do
    # A parent gets one feed for every child, so the split has to happen locally. This
    # is the part the upstream library gets wrong: it only ever sees the class-wide
    # entries and drops everything addressed to a pupil directly.
    it "gives a child both their personal and their class-wide items" do
      titles = timeline.for_student("113506").map { |item| JSON.parse(item["data"])["nazov"] }

      expect(titles).to contain_exactly("Jana personal", "4.A class-wide")
    end

    it "keeps siblings apart" do
      titles = timeline.for_student("-77").map { |item| JSON.parse(item["data"])["nazov"] }

      expect(titles).to contain_exactly("Peter personal", "2.A class-wide")
    end

    it "excludes items addressed to neither child" do
      expect(timeline.for_student("113506").map { |i| i["timelineid"] }).not_to include("5")
    end

    it "falls back to the whole feed for an unknown child" do
      expect(timeline.for_student("nobody").size).to eq(5)
    end
  end

  it "builds from a dashboard document without a second request" do
    document = Edupage::Parsers::Userhome.parse(
      Payloads.userhome_html(items: [Payloads.message_item(id: "9", recipient: "Student113506")])
    )

    feed = described_class.from_userhome(document)

    expect(feed.items.size).to eq(1)
    expect(feed.for_student("113506").size).to eq(1)
  end

  it "lists the userstrings that stand for a child" do
    expect(timeline.groups_for("113506")).to include("Student113506", "Trieda117967")
  end
end
