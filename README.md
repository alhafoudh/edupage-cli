# edupage-cli

Read-only prístup k účtu na [Edupage](https://www.edupage.org) - ako Ruby knižnica, CLI,
REST API a MCP server. Všetky štyri povrchy stoja na tom istom kóde a drží ich v súlade
parity test.

Edupage nemá verejné API. Každá stránka je server-rendered HTML s JSON-om zabaleným
v `<script>` blokoch a session si navyše drží skryté kurzory "aktuálne dieťa" a
"aktuálny školský rok", ktoré treba nastaviť skôr, než má fetch vôbec zmysel. Toto
všetko rieši knižnica za teba.

## Inštalácia

```bash
bundle install
bundle exec exe/edupage login
```

`login` heslo najprv overí voči Edupage a až potom ho uloží do macOS keychainu, takže
sa tam nikdy nedostane preklep.

## Credentials

Hľadajú sa v tomto poradí:

| Poradie | Zdroj |
|---|---|
| 1 | `EDUPAGE_USERNAME`, `EDUPAGE_PASSWORD`, `EDUPAGE_SCHOOL` |
| 2 | macOS keychain (service `edupage-cli`), cez `edupage login` |

`edupage auth` ukáže, ktorý zdroj sa práve používa, a upozorní, keď `EDUPAGE_PASSWORD`
prekrýva heslo v keychaine - inak by to vyzeralo, že `edupage login` nič neurobil.

Netajné nastavenia sú v `~/.config/edupage-cli/config.yml`, session a cache stránok
v `~/.cache/edupage-cli/`.

## Reťazec

Všetko visí na `account > škola > študent > ročník` a žiadna úroveň sa nedá preskočiť.
Každá sa rozhoduje rovnako: explicitný výber vyhráva, jediná možnosť sa vezme ticho,
čokoľvek iné skončí chybou so zoznamom možností.

```
$ edupage students
No school selected. Pick one:
  --school zsdemo   Základná škola Demo
  --school zusdemo  Základná umelecká škola Demo
```

Default v configu sa **za výber nepočíta**: `default_school` hovorí len to, na ktorý
`*.edupage.org` host sa prihlásiť, nikdy nie to, čie dáta čítaš.

Jedinou výnimkou je ročník - ten sa doplní na aktuálny, lebo "teraz" je jednoznačné.
Výstup vždy povie, ktorý rok použil, a keď je prázdny, ukáže, kde dáta sú:

```
$ edupage grades --school zsdemo --student Jana
school  : zsdemo  (Základná škola Demo)
student : Jana Nováková (4.A)
year    : 2026/2027 (current)  [default]
No records.
Nothing here for 2026/2027 (current). Try --year 2025 (172), --year 2024 (116).
```

## CLI

```bash
edupage schools
edupage students   --school zsdemo
edupage timetable  --school zsdemo --student Jana --from 2026-09-21 --to 2026-09-25
edupage homeworks  --school zsdemo --student Jana --due 2026-09-14
edupage years      --school zsdemo --student Jana
edupage grades     --school zsdemo --student Jana --year 2025 --term P1 --subject MAT
edupage timeline   --school zsdemo --student Peter --type message
```

Globálne prepínače: `--school --student --year --username --json --yaml --no-cache
--verbose`. Meno študenta stačí zadať ako unikátny prefix, takže `--student Jana`
postačuje.

Tabuľkový výstup má hlavičku s tým, z akej školy, študenta a roka dáta pochádzajú;
`--json` a `--yaml` ju nemajú, aby zostali bajt na bajt zhodné s REST a MCP odpoveďami.

Servisné príkazy: `edupage auth`, `edupage session status|refresh|logout`,
`edupage cache info|clear`, `edupage config path|get|set`.

## Knižnica

```ruby
require "edupage"

school = Edupage.account.school("zsdemo")
jana = school.students.find_by(name: /Jana/)

jana.timetable                                  # dnes
jana.timetable(Date.today..Date.today + 6)      # týždeň
jana.homeworks.where(subject: "SJL").order(:due_on)

jana.years                                      # 2026 (aktuálny), 2025, 2024 ...
jana.year(2025).grades.where(term: :P1, subject: "MAT")
jana.grades                                     # skratka pre aktuálny rok
```

Kolekcie sú lazy a reťaziteľné: `where order limit offset find_by first count`.
`where(name: ...)` hľadá naprieč menom, skratkou aj id záznamu; každý iný kľúč porovnáva
svoj atribút a berie hodnotu, regexp, range, pole alebo lambdu.

## Server

```bash
edupage server            # REST na /api/v1, MCP na /mcp
edupage mcp               # MCP cez stdio, pre editory a desktop klientov
```

Počúva na `127.0.0.1` a pri prvom spustení si vygeneruje bearer token do configu.
Všetky rúty sú `GET`, všetky MCP tooly sú označené ako read-only.

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:4567/api/v1/schools/zsdemo/students/Jana/years/2025/grades?term=P1"
```

### Zapojenie MCP

`edupage mcp-add` zaregistruje server u klienta, `edupage mcp-config` iba vypíše
`mcpServers` záznam, keď si ho chceš umiestniť sám.

```bash
edupage mcp-add claude-code --scope user    # cez `claude mcp add`
edupage mcp-add claude-desktop              # zlúči sa do claude_desktop_config.json
edupage mcp-add all --scope user            # oboje
edupage mcp-add all --dry-run               # ukáže, čo by spravil, nezmení nič
edupage mcp-add all --http                  # zaregistruje HTTP endpoint namiesto stdio

edupage mcp-config                          # len JSON a nič iné
edupage mcp-config --http
```

Pridávanie je **idempotentné**: zhodný záznam nechá tak, odlišný zosúladí a chýbajúci
doplní. Config Claude Desktopu sa zlučuje, nie prepisuje - ostatné servery aj nesúvisiace
nastavenia zostanú - a predošlá verzia sa odloží ako `.bak`.

Pre lokálny nástroj je lepší default stdio: proces vlastní klient, takže netreba nič
autentifikovať ani držať bežiaci server. `--http` mieri na `/mcp` bežiaceho
`edupage server` a nesie token v `Authorization` hlavičke, čo sa hodí, keď jeden proces
zdieľa viac klientov.

Ani jeden variant nepripína školu ani študenta - to sú úrovne reťazca a model si ich má
zvoliť pri každom volaní.

Vygenerovaný stdio záznam používa absolútne cesty a nastavuje `BUNDLE_GEMFILE`, lebo MCP
klienti spúšťajú servery z vlastného pracovného adresára. A spúšťajú ich aj **bez
nastaveného locale**, čo je dôvod, prečo každý súbor otvárame explicitne ako UTF-8
a nie cez `Encoding.default_external`.

## Ako povrchy zostávajú v súlade

Resources sú deklarované raz, v `lib/edupage/registry/resources.rb`:

```ruby
resource :grades do
  scope   :year
  summary "Grades for a school year"
  param   :term, type: :enum, values: %w[P1 P2], desc: "Half-year"
  resolve ->(year, p) { year.grades.where(term: p[:term]) }
end
```

Z toho sa vygeneruje CLI príkaz, REST rúta aj MCP tool a `spec/registry_parity_spec.rb`
spadne, ak niektorý chýba alebo sa mu rozídu parametre. Výstup `--json`, telo REST
odpovede aj výsledok MCP toolu idú cez jeden serializer, takže sú bajt na bajt zhodné.

`scope` zároveň deklaruje, na ktorých úrovniach reťazca resource stojí, takže ho všetky
tri povrchy vynucujú rovnako: REST ich nesie ako segmenty cesty, MCP input schéma ich
označí ako required a CLI odmietne so zoznamom možností.

## Poznámky k samotnému Edupage

Veci, ktoré stojí za to vedieť - všetky overené proti živému účtu:

- **Jeden login môže pokrývať viac škôl.** `mauth` vráti jednu session na každú školu.
- **Session drží aktuálne dieťa a aktuálny školský rok.** Prepnutie ktoréhokoľvek z nich
  je side effect na zdieľanom stave servera, takže prebieha pod file lockom a každá
  odpoveď sa kontroluje proti tomu, čo sa pýtalo.
- **Tieto prepnutia zaostávajú.** Edupage prepnutie potvrdí okamžite, ale ešte request
  alebo dva servíruje stránku predošlého dieťaťa či roka, takže sa fetch opakuje, kým sa
  stránka nezhoduje. Vrátiť zaostávajúcu stránku by potichu znamenalo rozvrh iného dieťaťa.
- **Číselníky sa medzi rokmi menia.** Zoznam tried za 2025 nie je ten istý ako za 2026,
  preto je rok súčasťou každého cache kľúča.
- **Timeline je spoločná pre všetky deti rodiča** a delí sa lokálne podľa mapy
  `childGroups`.
- **Domáce úlohy majú dva tvary** - zadané triede alebo jednému žiakovi. Treba oba: na
  účte, na ktorom to vzniklo, je 15 zo 16 úloh jedného dieťaťa toho druhého druhu.

## Vývoj

```bash
bundle exec rspec
```

Testy bežia proti ručne písaným payloadom, nie proti nahratým stránkam: tie skutočné
majú stovky kilobajtov a sú v nich mená cudzích detí.

CI beží na Ruby 3.2, 3.3 a 3.4 na Linuxe, plus jeden macOS job, ktorý si vytvorí vlastný
odomknutý keychain, aby sa keychain testy naozaj spustili a nepreskočili.

## Rozsah

Read-only, zámerne. Nič tu do Edupage nezapisuje - žiadne odpovede na správy, žiadne
označovanie úloh za hotové, žiadne podpisovanie známok. `spec/registry_parity_spec.rb`
aj samostatný CI job overujú, že sa v `lib/` neobjaví write endpoint.
