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

  def scrub(body)
    return body if body.nil? || body.empty?

    mapping = build_mapping(body)
    return body if mapping.empty?

    # Longest first, so "Jana Nováková" is replaced before the bare "Jana" inside it.
    text = mapping.keys.sort_by { |name| -name.length }
                  .reduce(body) { |acc, name| acc.gsub(name, mapping[name]) }

    scrub_inflections(text, mapping)
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
      next acc if stem.length < 4

      acc.gsub(/\b#{Regexp.escape(stem)}#{ENDING}\b/, fake)
    end
  end

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
    harvest(body, SCHOOL_FIELDS).each { |name| mapping[name] ||= school_name(name) }

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

  def compose_name(name, mapping)
    words = name.split(/\s+/)
    return full_name(name) if words.size < 2

    # Surnames are not always one word ("Al Hafoudh", "Kiss Nagyová"), so the split
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

  def school_name(real)
    with_seed(real) { "Základná škola #{Faker::Address.city}" }
  end

  def with_seed(real)
    previous = Faker::Config.random
    Faker::Config.random = Random.new(Digest::SHA256.hexdigest(real.to_s)[0, 12].to_i(16))
    yield
  ensure
    Faker::Config.random = previous
  end
end
