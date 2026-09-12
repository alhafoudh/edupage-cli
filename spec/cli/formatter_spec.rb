require "spec_helper"
require "unicode/display_width"

RSpec.describe Edupage::CLI::Formatter do
  # A stand-in for a model: the formatter only ever asks for table_fields by name.
  Row = Struct.new(:subject, :value, :title, keyword_init: true)

  # Mirrors what Registry::Resource exposes to the formatter.
  def resource(*fields)
    instance_double(Edupage::Registry::Resource, table_fields: fields)
  end

  def render(records, resource: nil, width: 80, format: :table)
    output = StringIO.new
    described_class.new(output: output, format: format, width: width)
                   .render(records, resource: resource)
    output.string
  end

  def line_widths(rendered)
    rendered.lines.map { |line| Unicode::DisplayWidth.of(line.chomp) }.uniq
  end

  let(:rows) do
    [
      Row.new(subject: "Matematika", value: "1", title: "Písomka"),
      Row.new(subject: "Slovenský jazyk", value: "2-", title: "Diktát")
    ]
  end

  it "draws a unicode frame with a header row" do
    rendered = render(rows, resource: resource(:subject, :value, :title))

    expect(rendered).to eq(<<~TABLE)
      ┌─────────────────┬───────┬─────────┐
      │ subject         │ value │ title   │
      ├─────────────────┼───────┼─────────┤
      │ Matematika      │ 1     │ Písomka │
      │ Slovenský jazyk │ 2-    │ Diktát  │
      └─────────────────┴───────┴─────────┘
    TABLE
  end

  it "says so instead of drawing an empty frame" do
    expect(render([])).to eq("No records.\n")
  end

  it "keeps the table inside the terminal width" do
    long = Row.new(subject: "Matematika", value: "1",
                   title: "Písomka z kvadratických rovníc a nerovníc s naozaj dlhým názvom")

    rendered = render([long], resource: resource(:subject, :value, :title), width: 60)

    expect(line_widths(rendered)).to eq([60])
    expect(rendered).to include("Písomka z")
  end

  # Regression: strings 0.2.1 keeps the space after a word that ends exactly on the
  # wrap boundary and returns a line one character too wide, which tears the frame.
  it "stays aligned when a word ends exactly on the wrap boundary" do
    row = Row.new(subject: "x", value: "y", title: "aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc dddd")

    rendered = render([row], resource: resource(:subject, :value, :title), width: 30)

    expect(line_widths(rendered).size).to eq(1)
  end

  it "wraps a newline inside a cell onto its own line" do
    row = Row.new(subject: "Matematika", value: "1", title: "Diktát\ns novým riadkom")

    rendered = render([row], resource: resource(:subject, :value, :title))

    expect(rendered).to include("│ Diktát")
    expect(rendered).to include("│ s novým riadkom")
  end

  it "falls back to the record's own keys when the resource declares no columns" do
    rendered = render([Row.new(subject: "Matematika", value: "1", title: "Písomka")])

    expect(rendered).to include("subject")
    expect(rendered).to include("Matematika")
  end

  # The JSON and YAML paths go through Serializer and have to stay byte-identical to
  # what the REST API and the MCP tools return, so the table rewrite must not touch them.
  it "leaves JSON output alone" do
    rendered = render([{ subject: "Matematika", value: "1" }], format: :json)

    expect(JSON.parse(rendered)).to eq([{ "subject" => "Matematika", "value" => "1" }])
  end

  it "leaves YAML output alone" do
    rendered = render([{ subject: "Matematika", value: "1" }], format: :yaml)

    expect(YAML.safe_load(rendered)).to eq([{ "subject" => "Matematika", "value" => "1" }])
  end
end

RSpec.describe Edupage::CLI::Table do
  describe ".plain" do
    it "aligns columns with a single space between them and no trailing blanks" do
      rendered = described_class.plain([["school", ":", "zsdemo"], ["student", ":", "Jano"]])

      expect(rendered).to eq("school  : zsdemo\nstudent : Jano")
    end

    it "indents every line" do
      rendered = described_class.plain([["--year", "2024", "12 grades"]], indent: 2)

      expect(rendered).to eq("  --year 2024 12 grades")
    end

    it "renders nothing for no rows" do
      expect(described_class.plain([])).to eq("")
    end
  end
end
