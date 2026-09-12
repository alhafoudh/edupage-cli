require "digest"
require "faker"

# Replaces real people and schools in a VCR cassette before it is written to disk.
#
# Recording runs against a live account, so the responses are full of other people's
# children, their teachers and the school's name. None of that belongs in a repository,
# and a filter that only knew a fixed list of names would silently stop working the day
# a new classmate appears.
#
# So the names are harvested from the response itself - from the fields where Edupage
# always puts them - and every occurrence of each harvested value is replaced, including
# the ones sitting in free text such as message bodies and homework titles.
#
# The pseudonym is derived from the real value, so the same person is the same fake
# person in every cassette and cross-references inside a payload stay intact. It is a
# one-way mapping: the cassette gives no way back to the original.
module CassetteScrubber
  # Fields whose value is always a person's given name.
  FIRST_NAME_FIELDS = %w[firstname].freeze

  # ... a surname.
  LAST_NAME_FIELDS = %w[lastname].freeze

  # ... a display name, usually "First Last", sometimes a group such as "Celá škola".
  FULL_NAME_FIELDS = %w[user_meno vlastnik_meno ucitel_meno autor_meno loggedUserName
                        loggedUserFullName].freeze

  # ... the school's name.
  SCHOOL_FIELDS = %w[school_name schoolName].freeze

  # The school's subdomain identifies it just as plainly as its name, and it is in every
  # single URL. Edupage spells it out in these places.
  # The last two matter for a parent whose children attend more than one school: the
  # other schools appear only in the profile switcher, never as a URL or an ASC value.
  ORIGIN_PATTERNS = [
    /ASC\.edupage\s*=\s*"([a-z0-9-]+)"/i,
    /\\?"edupage\\?"\s*:\s*\\?"([a-z0-9-]+)\\?"/,
    %r{https?://([a-z0-9-]+)\.edupage\.org}i,
    /edupage;([a-z0-9-]+);/,
    /userEdupage\\?"\s*>\s*([a-z0-9-]+)\s*</
  ].freeze

  # Login names are e-mail addresses and appear in the page as well as in erid strings.
  EMAIL = /[\w.+-]+@[\w-]+\.[\w.-]+/

  # Subdomains that are not a school.
  RESERVED_ORIGINS = %w[login1 login2 www portal 404].freeze

  # Generic words in a school's name. Everything else in it is the part that identifies
  # the school, and is replaced word by word - free text abbreviates the name
  # ("v ZŠ Jána Hollého"), so replacing only the full string leaves the telling half behind.
  SCHOOL_STOPWORDS = %w[
    základná stredná materská umelecká súkromná cirkevná spojená odborná internátna
    škola školy školu školou gymnázium konzervatórium akadémia a s so pre
  ].freeze

  # Display names that are groups rather than people; replacing them would only make
  # the cassette harder to read.
  GROUPS = ["Celá škola", "Administrátor", "Rodičia", "Žiaci"].freeze

  # userrow holds the logged-in user's own name under keys that mean something else
  # elsewhere in the payload: p_meno is the grade event's title on the grades page.
  # Harvesting only from the unambiguous fields above avoids mangling those.
  USERROW = /"userrow"\s*:\s*\{(.*?)\}/m

  module_function

  # Letters a Slovak ending can be made of, for the inflection pass below.
  ENDING = "[a-záäčďéíĺľňóôŕšťúýžA-ZÁÄČĎÉÍĹĽŇÓÔŔŠŤÚÝŽ]{0,3}".freeze

  # Scrubs a whole VCR interaction under one mapping.
  #
  # The URI matters as much as the body: every request carries the school's subdomain,
  # so a cassette whose bodies were cleaned but whose URLs still read
  # https://realschool.edupage.org/... has not been anonymised at all.
  def scrub_interaction(interaction)
    # Headers count too: Host, Referer and Location all spell the school out, and a
    # cassette is not anonymous while any of them does.
    source = [
      interaction.request.uri,
      interaction.request.body,
      interaction.response.body,
      header_values(interaction.request.headers),
      header_values(interaction.response.headers)
    ].compact.map { |part| as_utf8(part) }.join("\n")

    mapping = build_mapping(source)
    return interaction if mapping.empty?

    interaction.request.uri = apply(interaction.request.uri, mapping)
    interaction.request.body = apply(interaction.request.body, mapping)
    interaction.response.body = apply(interaction.response.body, mapping)
    scrub_headers(interaction.request.headers, mapping)
    scrub_headers(interaction.response.headers, mapping)
    interaction
  end

  def header_values(headers)
    return nil if headers.nil?

    headers.values.flatten.compact.join("\n")
  end

  def scrub_headers(headers, mapping)
    return if headers.nil?

    headers.each_value do |values|
      values.map! { |value| value.is_a?(String) ? apply(value, mapping) : value }
    end
  end

  def scrub(body)
    return body if body.nil? || body.empty?

    apply(body, build_mapping(body))
  end

  def apply(text, mapping)
    return text if text.nil? || text.empty? || mapping.empty?

    # HTTP bodies arrive as binary, and the accented names here cannot be matched by a
    # UTF-8 regexp against an ASCII-8BIT string.
    text = as_utf8(text)

    # Longest first, so "Jana Nováková" is replaced before the bare "Jana" inside it.
    # Anything long enough to be a name is matched regardless of case: the same word
    # turns up shouted in a room label ("BELA (Hlavná budova)") as well as capitalised
    # in the directory.
    replaced = mapping.keys.sort_by { |name| -name.length }.reduce(text) do |acc, name|
      name.length >= 4 ? acc.gsub(/#{Regexp.escape(name)}/i, mapping[name]) : acc.gsub(name, mapping[name])
    end

    scrub_inflections(replaced, mapping)
  end

  # Raised rather than silently dropping bytes: a body this cannot read is a body it
  # cannot anonymise, and writing it out regardless would put real names on disk in a
  # form no leak check would spot.
  class UnreadableBody < StandardError; end

  def as_utf8(text)
    return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

    candidate = text.dup.force_encoding(Encoding::UTF_8)
    return candidate if candidate.valid_encoding?

    raise UnreadableBody,
          "Cannot scrub a body that is not UTF-8 text (#{text.bytesize} bytes). " \
          "If it is compressed, decompress it before recording; if it is binary, it " \
          "must not be recorded at all."
  end

  # Slovak declines names, so a message body says "Pre Zoru" where the directory says
  # "Zora". Exact replacement alone leaves those behind, which is precisely the kind
  # of leftover nobody would notice in a 300 KB cassette.
  #
  # Each name also gets replaced in any form that shares its stem. The result reads
  # ungrammatically - the pseudonym is never declined - but a cassette is evidence, not
  # prose.
  def scrub_inflections(text, mapping)
    word_mapping(mapping).sort_by { |word, _| -word.length }.reduce(text) do |acc, (word, fake)|
      stem = stem_of(word)
      next acc if stem.length < MIN_STEM

      acc.gsub(/\b#{Regexp.escape(stem)}#{ENDING}\b/, fake)
    end
  end

  # Short enough to catch "Zoru" from "Zora" - a four-character floor would miss every
  # short name, which is most of them. Over-scrubbing a word that merely shares a stem
  # costs nothing here; under-scrubbing costs a name on disk.
  MIN_STEM = 3

  # Full display names are harvested whole, so their parts would otherwise have no
  # entry of their own to inflect from.
  def word_mapping(mapping)
    mapping.each_with_object({}) do |(real, fake), result|
      real_words = real.split(/\s+/)
      fake_words = fake.split(/\s+/)
      next unless real_words.size == fake_words.size

      real_words.zip(fake_words).each do |real_word, fake_word|
        result[real_word] ||= fake_word if real_word.length >= 4
      end
    end
  end

  # Drops a trailing vowel so "Zora" also matches "Zoru" and "Zory".
  def stem_of(word)
    word.sub(/[aáeéiíoóuúyý]\z/, "")
  end

  def build_mapping(body)
    mapping = {}

    harvest(body, FIRST_NAME_FIELDS).each { |name| mapping[name] ||= first_name(name) }
    harvest(body, LAST_NAME_FIELDS).each { |name| mapping[name] ||= last_name(name) }
    harvest(body, SCHOOL_FIELDS).each { |name| add_school(name, mapping) }
    harvest_origins(body).each { |origin| mapping[origin] ||= origin_name(origin) }
    body.scan(EMAIL).uniq.each { |address| mapping[address] ||= email(address) }

    # The logged-in user's own name, which only userrow spells out.
    body.scan(USERROW).flatten.each do |row|
      harvest(row, %w[p_meno]).each { |name| mapping[name] ||= first_name(name) }
      harvest(row, %w[p_priezvisko]).each { |name| mapping[name] ||= last_name(name) }
    end

    # Display names last, composed from the parts already mapped above, so the pupil
    # listed in dbi and the same pupil named on a timeline item become the same fake
    # person. Anything matching them up by name keeps working against the cassette.
    harvest(body, FULL_NAME_FIELDS).each do |name|
      next if GROUPS.any? { |group| name.start_with?(group) }

      mapping[name] ||= compose_name(name, mapping)
    end

    mapping.reject { |name, _| name.strip.empty? }
  end

  # Maps the identifying words of a school's name individually, then composes the full
  # name from them, so "Základná škola Jána Hollého" and a later "ZŠ Jána Hollého" end up
  # naming the same invented school.
  def add_school(name, mapping)
    words = name.split(/\s+/)

    words.each do |word|
      bare = word.gsub(/[^[:alpha:]]/, "")
      next if bare.length < 3 || SCHOOL_STOPWORDS.include?(bare.downcase)

      mapping[word] ||= school_word(word)
    end

    mapping[name] ||= words.map { |word| mapping[word] || word }.join(" ")
  end

  def compose_name(name, mapping)
    words = name.split(/\s+/)
    return full_name(name) if words.size < 2

    # Surnames are not always one word ("Ben Omar", "Kiss Nagyová"), so the split
    # is chosen by what the directory already told us rather than assumed to be the
    # first space.
    (1...words.size).each do |index|
      given = words[0, index].join(" ")
      family = words[index..].join(" ")
      return "#{mapping[given]} #{mapping[family]}" if mapping[given] && mapping[family]
    end

    words.each_with_index
         .map { |word, index| mapping[word] || (index.zero? ? first_name(word) : last_name(word)) }
         .join(" ")
  end

  def harvest_origins(body)
    ORIGIN_PATTERNS.flat_map { |pattern| body.scan(pattern).flatten }
                   .uniq
                   .reject { |origin| origin.empty? || RESERVED_ORIGINS.include?(origin) }
  end

  # Values are read from both plain JSON and the JSON that Edupage embeds as an escaped
  # string inside another JSON document.
  def harvest(body, fields)
    fields.flat_map do |field|
      body.scan(/\\?"#{Regexp.escape(field)}\\?"\s*:\s*\\?"((?:[^"\\]|\\.)*)\\?"/)
          .flatten
          .map { |value| value.gsub('\\"', '"') }
    end.uniq.reject(&:empty?)
  end

  # --- pseudonyms ---------------------------------------------------------------------
  #
  # Seeded from the real value so the mapping is stable across runs and cassettes
  # without keeping any state on disk.

  def first_name(real) = with_seed(real) { Faker::Name.first_name }
  def last_name(real) = with_seed(real) { Faker::Name.last_name }

  def full_name(real)
    with_seed(real) { "#{Faker::Name.first_name} #{Faker::Name.last_name}" }
  end

  def school_word(real)
    with_seed(real) { Faker::Address.city.gsub(/\s+/, "") }
  end

  def origin_name(real)
    with_seed(real) { "zs#{Faker::Internet.domain_word.gsub(/[^a-z0-9]/, "")}" }
  end

  def email(real)
    with_seed(real) { Faker::Internet.email(domain: "example.com") }
  end

  def with_seed(real)
    previous = Faker::Config.random
    Faker::Config.random = Random.new(Digest::SHA256.hexdigest(real.to_s)[0, 12].to_i(16))
    yield
  ensure
    Faker::Config.random = previous
  end
end
