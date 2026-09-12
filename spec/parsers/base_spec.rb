RSpec.describe Edupage::Parsers::Base do
  describe ".extract_blob" do
    it "extracts a plain object argument" do
      html = %(<script>$j(x).userhome({"a":1,"b":[1,2]});</script>)

      expect(described_class.extract_blob(html, ".userhome")).to eq("a" => 1, "b" => [1, 2])
    end

    it "survives a closing paren inside a string value" do
      # This is what breaks the upstream regex: homework titles and message bodies
      # regularly contain ");" and the non-greedy match stops there.
      html = %(<script>.userhome({"title":"str.5/6 (dokoncit); zvysok","id":7});</script>)

      expect(described_class.extract_blob(html, ".userhome"))
        .to eq("title" => "str.5/6 (dokoncit); zvysok", "id" => 7)
    end

    it "survives escaped quotes and braces inside strings" do
      html = %(<script>.userhome({"t":"a \\"quoted\\" {brace} value","n":1});</script>)

      expect(described_class.extract_blob(html, ".userhome")["t"]).to eq('a "quoted" {brace} value')
    end

    it "handles nested structures" do
      html = %(<script>.userhome({"dbi":{"classes":{"1":{"name":"2.A"}}},"dp":{"dates":{}}});</script>)

      expect(described_class.extract_blob(html, ".userhome").dig("dbi", "classes", "1", "name"))
        .to eq("2.A")
    end

    it "accepts an array argument" do
      html = %(<script>.fill([{"a":1}]);</script>)

      expect(described_class.extract_blob(html, ".fill")).to eq([{ "a" => 1 }])
    end

    it "skips calls whose argument is not a JSON literal" do
      html = %(<script>.userhome(someVariable); .userhome({"real":true});</script>)

      expect(described_class.extract_blob(html, ".userhome")).to eq("real" => true)
    end

    it "tolerates whitespace between the name and the argument" do
      html = %(<script>.userhome (\n  {"a":1}\n);</script>)

      expect(described_class.extract_blob(html, ".userhome")).to eq("a" => 1)
    end

    it "returns nil when the call is absent" do
      expect(described_class.extract_blob("<html></html>", ".userhome")).to be_nil
    end

    it "keeps its bearings in a document full of multibyte characters" do
      # StringScanner#pos counts bytes while String#[] counts characters. Mixing them
      # drifts by one position per non-ASCII character and eventually mistakes a quote
      # inside a string for the end of it.
      padding = "Ásványiová Antalíková čšťžýáíé" * 200
      html = %(<script>/* #{padding} */ .userhome({"name":"Bartalová","note":"#{padding}"});</script>)

      result = described_class.extract_blob(html, ".userhome")

      expect(result["name"]).to eq("Bartalová")
      expect(result["note"]).to eq(padding)
      expect(result["name"].encoding).to eq(Encoding::UTF_8)
    end

    it "skips over a JSON document embedded as an escaped string" do
      # Timeline items carry their payload this way, so the inner braces and brackets
      # must not be counted.
      inner = %({"confirmedTargets":[1554],"targetNames":["Áno"],"hasTargets":true})
      html = %(<script>.userhome({"data":#{inner.to_json},"after":1});</script>)

      result = described_class.extract_blob(html, ".userhome")

      expect(result["after"]).to eq(1)
      expect(JSON.parse(result["data"])["targetNames"]).to eq(["Áno"])
    end

    it "handles a string ending in an escaped backslash" do
      html = %(<script>.userhome({"path":"C:\\\\","next":2});</script>)

      expect(described_class.extract_blob(html, ".userhome")).to eq("path" => "C:\\", "next" => 2)
    end

    it "raises with a snippet when the argument is malformed JSON" do
      html = %(<script>.userhome({"a":});</script>)

      expect { described_class.extract_blob(html, ".userhome") }
        .to raise_error(Edupage::ParseError, /not valid JSON/)
    end
  end

  describe ".extract_blob!" do
    it "raises when the call is absent" do
      expect { described_class.extract_blob!("<html></html>", ".userhome") }
        .to raise_error(Edupage::ParseError, /Could not find/)
    end
  end

  describe ".extract_assignments" do
    it "reads ASC.* assignments" do
      html = <<~HTML
        <script>
          ASC.gsechash = "803e65e8";
          ASC.gpid = 62780423;
          ASC.lang = "sk";
          ASC.req_props = {"a":1};
          ASC.someFn = function() { return 1; };
        </script>
      HTML

      result = described_class.extract_assignments(html, "ASC")

      expect(result["gsechash"]).to eq("803e65e8")
      expect(result["gpid"]).to eq(62_780_423)
      expect(result["lang"]).to eq("sk")
      expect(result).not_to have_key("someFn")
    end
  end
end
