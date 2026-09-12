# Stand-in models so the relation is exercised on its own terms rather than through
# whatever a real model happens to expose.
class SpecSubject < Edupage::Model
  attribute :name
  attribute :short
end

class SpecItem < Edupage::Model
  attribute :title
  attribute :due, "due", cast: :date
  attribute :kind
  attribute(:subject) { |d| d["subject"] }
end

RSpec.describe Edupage::Relation do
  # Braces are required: a trailing bare hash would be taken as keyword arguments.
  def subject_for(name, short) = SpecSubject.new({ "id" => short, "name" => name, "short" => short })

  let(:math) { subject_for("Matematika", "MAT") }
  let(:slovak) { subject_for("Slovenský jazyk a literatúra", "SJL") }

  let(:records) do
    [
      SpecItem.new({ "id" => "1", "title" => "Alpha", "due" => "2026-09-14", "kind" => "hw", "subject" => math }),
      SpecItem.new({ "id" => "2", "title" => "Beta", "due" => "2026-09-11", "kind" => "test", "subject" => slovak }),
      SpecItem.new({ "id" => "3", "title" => "Gamma", "due" => nil, "kind" => "hw", "subject" => math })
    ]
  end

  describe "laziness" do
    it "does not call the loader until enumerated" do
      calls = 0
      relation = described_class.new(-> { calls += 1; records })

      relation.where(kind: "hw").order(:due).limit(1)
      expect(calls).to eq(0)

      relation.where(kind: "hw").to_a
      expect(calls).to eq(1)
    end

    it "loads only once per relation" do
      calls = 0
      relation = described_class.new(-> { calls += 1; records })

      relation.to_a
      relation.count
      relation.first

      expect(calls).to eq(1)
    end

    it "leaves the parent relation untouched when chained" do
      relation = described_class.wrap(records)
      filtered = relation.where(kind: "test")

      expect(filtered.count).to eq(1)
      expect(relation.count).to eq(3)
    end
  end

  describe "#where" do
    let(:relation) { described_class.wrap(records) }

    it "matches exact values case-insensitively" do
      expect(relation.where(title: "alpha").map(&:title)).to eq(["Alpha"])
    end

    it "matches a regexp" do
      expect(relation.where(title: /a$/).map(&:title)).to contain_exactly("Alpha", "Beta", "Gamma")
    end

    it "matches any value in an array" do
      expect(relation.where(kind: %w[test hw]).count).to eq(3)
      expect(relation.where(kind: %w[test]).count).to eq(1)
    end

    it "matches a range and ignores nil values" do
      expect(relation.where(due: Date.new(2026, 9, 12)..).map(&:title)).to eq(["Alpha"])
    end

    it "matches a nested model by either its name or its short code" do
      expect(relation.where(subject: "MAT").count).to eq(2)
      expect(relation.where(subject: "Matematika").count).to eq(2)
      expect(relation.where(subject: math).count).to eq(2)
    end

    it "accepts a predicate" do
      expect(relation.where(due: ->(d) { d.nil? }).map(&:title)).to eq(["Gamma"])
    end

    it "ANDs successive conditions" do
      expect(relation.where(kind: "hw").where(subject: "MAT").count).to eq(2)
      expect(relation.where(kind: "test").where(subject: "MAT").count).to eq(0)
    end

    it "ignores a nil condition so optional CLI filters need no special casing" do
      expect(relation.where(kind: nil).count).to eq(3)
    end

    it "searches the whole record when filtering by name" do
      # `--name MAT` has to find "Matematika": name is the one key that matches against
      # everything identifying the record, not just its name attribute.
      subjects = described_class.wrap([math, slovak])

      expect(subjects.where(name: "MAT").map(&:short)).to eq(["MAT"])
      expect(subjects.where(name: "Matematika").map(&:short)).to eq(["MAT"])
      expect(subjects.where(name: /slovensk/i).map(&:short)).to eq(["SJL"])
      expect(subjects.where(name: %w[MAT SJL]).count).to eq(2)
    end

    it "excludes records that do not have the attribute" do
      expect(relation.where(nonexistent: "x").count).to eq(0)
    end
  end

  describe "#order" do
    let(:relation) { described_class.wrap(records) }

    it "sorts ascending and puts nil last" do
      expect(relation.order(:due).map(&:title)).to eq(%w[Beta Alpha Gamma])
    end

    it "sorts descending" do
      expect(relation.order(due: :desc).map(&:title)).to eq(%w[Gamma Alpha Beta])
    end

    it "sorts by a nested model's name" do
      expect(relation.order(:subject).first.subject.short).to eq("MAT")
    end

    it "applies several keys in order" do
      # kind first ("hw" before "test"), then due within each kind, nil last.
      expect(relation.order(:kind, :due).map(&:title)).to eq(%w[Alpha Gamma Beta])
    end
  end

  describe "#limit and #offset" do
    let(:relation) { described_class.wrap(records).order(:title) }

    it "limits" do
      expect(relation.limit(2).map(&:title)).to eq(%w[Alpha Beta])
    end

    it "offsets" do
      expect(relation.offset(1).map(&:title)).to eq(%w[Beta Gamma])
    end

    it "combines both" do
      expect(relation.offset(1).limit(1).map(&:title)).to eq(["Beta"])
    end
  end

  describe "lookups" do
    let(:relation) { described_class.wrap(records) }

    it "finds by conditions" do
      expect(relation.find_by(kind: "test").title).to eq("Beta")
      expect(relation.find_by(kind: "nope")).to be_nil
    end

    it "finds by id" do
      expect(relation.find("2").title).to eq("Beta")
    end

    it "is Enumerable" do
      expect(relation.map(&:title)).to contain_exactly("Alpha", "Beta", "Gamma")
      expect(relation.select { |r| r.kind == "hw" }.size).to eq(2)
      expect(relation).to respond_to(:each, :map, :select, :group_by)
    end
  end
end
