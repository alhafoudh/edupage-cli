require_relative "cassette_scrubber"

RSpec.describe CassetteScrubber do
  # Shaped like a real /user/ response: dbi with people, a timeline item whose payload
  # is JSON escaped inside a JSON string, and the school's name in an ASC assignment.
  let(:body) do
    <<~JSON
      {"dbi":{"students":{"1":{"firstname":"Zora","lastname":"Nováková","classid":"7"},
                          "2":{"firstname":"Oliver","lastname":"Nováková"}},
              "teachers":{"9":{"firstname":"Anna","lastname":"Vargová","short":"Gl"}}},
       "school_name":"Základná škola Jána Hollého",
       "userrow":{"p_meno":"Ahmed","p_priezvisko":"Nováková","p_mail":"x@example.com"},
       "items":[{"user_meno":"Zora Nováková","vlastnik_meno":"Anna Vargová",
                 "text":"Zora zabudla zošit, píše Anna Vargová",
                 "data":"{\\"nazov\\":\\"Pre Zoru\\",\\"ucitel_meno\\":\\"Anna Vargová\\"}"}]}
    JSON
  end

  subject(:scrubbed) { described_class.scrub(body) }

  it "removes every harvested name from the cassette" do
    %w[Zora Oliver Nováková Vargová Anna].each do |name|
      expect(scrubbed).not_to include(name), "#{name} survived"
    end
  end

  it "removes the school's name" do
    expect(scrubbed).not_to include("Jána Hollého")
    expect(scrubbed).to match(/"school_name":"Základná škola \w+/)
  end

  it "reaches names sitting in free text, not just in their own fields" do
    # "Zora zabudla zošit" is prose in a message body; a field-by-field filter would
    # leave it behind.
    expect(scrubbed).not_to match(/zabudla zošit, píše Zora|Zora zabudla/)
    expect(scrubbed).to match(/\w+ zabudla zošit, píše \w+ \w+/)
  end

  it "reaches names inside JSON escaped into a JSON string" do
    expect(scrubbed).not_to include("Pre Zoru".sub("u", "")) # "Pre Terez"
    expect(scrubbed).to include('\\"ucitel_meno\\":')
  end

  it "keeps the document parseable and the structure intact" do
    parsed = JSON.parse(scrubbed)

    expect(parsed.dig("dbi", "students", "1")).to have_key("firstname")
    expect(parsed.dig("dbi", "students", "1", "classid")).to eq("7")
    expect(parsed.dig("dbi", "teachers", "9", "short")).to eq("Gl")
  end

  it "gives the same person the same pseudonym in the directory and on the timeline" do
    # Anything that matches a timeline item to a pupil by name has to keep working
    # against the cassette, so the two spellings must agree.
    parsed = JSON.parse(scrubbed)
    student = parsed.dig("dbi", "students", "1")

    expect(parsed.dig("items", 0, "user_meno"))
      .to eq("#{student["firstname"]} #{student["lastname"]}")
  end

  it "handles a surname made of several words" do
    # "Al Hafoudh", "Kiss Nagyová" - splitting on the first space would scatter
    # the pupil into a different fake person than the directory has.
    body = %({"dbi":{"students":{"1":{"firstname":"Jana","lastname":"Al Hafoudh"}}},) +
           %("items":[{"user_meno":"Jana Al Hafoudh"}]})
    parsed = JSON.parse(described_class.scrub(body))
    student = parsed.dig("dbi", "students", "1")

    expect(parsed.dig("items", 0, "user_meno"))
      .to eq("#{student["firstname"]} #{student["lastname"]}")
    expect(described_class.scrub(body)).not_to include("Hafoudh")
  end

  it "keeps a shared surname shared" do
    parsed = JSON.parse(scrubbed)

    expect(parsed.dig("dbi", "students", "2", "lastname"))
      .to eq(parsed.dig("dbi", "students", "1", "lastname"))
  end

  it "is deterministic across runs" do
    expect(described_class.scrub(body)).to eq(described_class.scrub(body))
  end

  it "maps different people to different pseudonyms" do
    parsed = JSON.parse(scrubbed)

    expect(parsed.dig("dbi", "students", "1", "firstname"))
      .not_to eq(parsed.dig("dbi", "students", "2", "firstname"))
  end

  it "leaves group recipients readable" do
    group = described_class.scrub(%({"user_meno":"Celá škola","firstname":"Zora"}))

    expect(group).to include("Celá škola")
    expect(group).not_to include("Zora")
  end

  it "passes through a body with nothing to scrub" do
    expect(described_class.scrub(%({"a":1}))).to eq(%({"a":1}))
    expect(described_class.scrub(nil)).to be_nil
    expect(described_class.scrub("")).to eq("")
  end

  it "does not touch grade titles, which live under a key that means a name elsewhere" do
    # On the grades page p_meno is the event's title, not a person.
    grades = %({"vsetkyUdalosti":{"edupage":{"1":{"p_meno":"Písomná práca"}}}})

    expect(described_class.scrub(grades)).to include("Písomná práca")
  end
end
