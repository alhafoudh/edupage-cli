# edupage-cli

Read-only prístup k účtu na [Edupage](https://www.edupage.org) - ako Ruby knižnica, CLI,
REST API a MCP server. Všetky štyri rozhrania používajú rovnaký kód a ich zhodu
stráži parity test.

Edupage nemá verejné API. Každá stránka je HTML vygenerované na serveri s JSON-om
vloženým do blokov `<script>`. Session si navyše interne pamätá "aktuálne dieťa"
a "aktuálny školský rok", ktoré treba nastaviť pred načítaním dát. Toto všetko
rieši knižnica za teba.

## Inštalácia

### Inštalácia jedným príkazom

**macOS (funguje aj na Linuxe)**

```bash
curl -fsSL https://raw.githubusercontent.com/alhafoudh/edupage-cli/main/install.sh | sh
```

Skript použije Homebrew, ak je dostupný, inak nainštaluje gem cez Ruby 3.2 alebo novšie.
Ak nie je dostupná ani jedna možnosť, skončí s pokynmi. Homebrew ani Ruby sám neinštaluje.

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/alhafoudh/edupage-cli/main/install.ps1 | iex
```

Skript použije existujúce Ruby 3.2 alebo novšie. Ak Ruby nie je nainštalované vôbec,
nainštaluje Ruby+Devkit 3.4 cez winget a nástroje MSYS2 na zostavovanie cez `ridk install`. Potom
nainštaluje gem edupage-cli. Na Windows na ARM navyše nainštaluje libxml2/libxslt z MSYS2
a zostaví s nimi nokogiri, pretože pre arm64 Windows nie je dostupný predkompilovaný gem.

Na Windows nie je dostupný macOS keychain, preto `edupage login` nefunguje. Prihlasovacie
údaje nastav cez premenné prostredia:

```powershell
setx EDUPAGE_USERNAME "tvoje_pouzivatelske_meno"
setx EDUPAGE_PASSWORD "tvoje_heslo"
setx EDUPAGE_SCHOOL "tvoja_skola"
```

Po nastavení otvor nové okno terminálu, aby sa premenné načítali.

edupage-cli si môžeš nainštalovať aj manuálne nasledujúcimi spôsobmi.

### Ručná inštalácia

Cez Homebrew na macOS aj Linuxe:

```bash
brew install alhafoudh/edupage/edupage-cli
edupage login
```

Formula je v tape [alhafoudh/homebrew-edupage](https://github.com/alhafoudh/homebrew-edupage).
Zostavuje sa zo zdrojového kódu označeného tagom, používa Ruby z Homebrew a gemy si
ukladá oddelene, takže nezasahuje do ostatných inštalácií Ruby. Pri prvej inštalácii sa kompiluje zopár natívnych
gemov (puma, nio4r), čo trvá pár desiatok sekúnd.

Alebo ako gem, ak už Ruby 3.2+ máš:

```bash
gem install edupage-cli
```

Alebo priamo z checkoutu:

```bash
bundle install
bundle exec exe/edupage login
```

`login` najprv overí heslo prihlásením do Edupage a až potom ho uloží do macOS
keychainu, takže heslo s preklepom neuloží.

## Prihlasovacie údaje

Hľadajú sa v tomto poradí:

| Poradie | Zdroj |
|---|---|
| 1 | `EDUPAGE_USERNAME`, `EDUPAGE_PASSWORD`, `EDUPAGE_SCHOOL` |
| 2 | macOS keychain (service `edupage-cli`), cez `edupage login` |

`edupage auth` ukáže, ktorý zdroj sa práve používa, a upozorní, keď má `EDUPAGE_PASSWORD`
prednosť pred heslom v keychaine - inak by to vyzeralo, že `edupage login` nič neurobil.

Nastavenia bez citlivých údajov sú v `~/.config/edupage-cli/config.yml`, session a cache stránok
v `~/.cache/edupage-cli/`.

## Hierarchia výberu

Výber sa riadi hierarchiou `account > škola > študent > školský rok` a žiadna úroveň
sa nedá preskočiť. Na každej úrovni platí rovnaké pravidlo: prednosť má explicitný
výber, jediná možnosť sa vyberie automaticky a v ostatných prípadoch príkaz skončí
chybou so zoznamom možností.

```
$ edupage students
No school selected. Pick one:
  --school zsdemo  Základná škola Demo
  --school zusdemo Základná umelecká škola Demo
```

Predvolená hodnota v configu sa **za výber nepočíta**: `default_school` určuje iba
server `*.edupage.org`, na ktorý sa prihlásiť, nie to, čie dáta čítaš.

Jedinou výnimkou je školský rok - automaticky sa vyberie aktuálny, lebo "teraz" je
jednoznačné. Vo výstupe je vždy uvedené, ktorý rok sa použil, a ak preň nie sú žiadne
dáta, výstup ukáže, v ktorých rokoch sú:

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

Tabuľkový výstup má hlavičku s údajmi o škole, študentovi a školskom roku. Výstupy
`--json` a `--yaml` hlavičku nemajú, aby boli bajt po bajte zhodné s odpoveďami REST API
a MCP.

```
$ edupage grades --school zsdemo --student Jana --year 2025
school  : zsdemo  (Základná škola Demo)
student : Jana Nováková (4.A)
year    : 2025/2026
┌──────────────────┬───────────────────────────────┬───────┬────────┬─────────────────────────┐
│ created at       │ subject                       │ value │ weight │ title                   │
├──────────────────┼───────────────────────────────┼───────┼────────┼─────────────────────────┤
│ 2025-09-13 10:53 │ Slovenský jazyk a literatúra  │ 1     │ 1.0    │ Čítanie                 │
│ 2025-09-20 08:16 │ Matematika                    │ 1     │ 1.0    │ Sčítanie a odčítanie    │
│                  │                               │       │        │ do 20 bez prechodu      │
└──────────────────┴───────────────────────────────┴───────┴────────┴─────────────────────────┘
```

Tabuľka sa prispôsobí šírke terminálu: keď sa nezmestí, vždy sa zúži najširší
stĺpec a dlhý text sa zalomí, takže dátumy a známky zostanú celé.

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
`where(name: ...)` hľadá v mene, skratke aj id záznamu; pri ostatných kľúčoch sa
porovnáva príslušný atribút. Ako podmienku možno zadať hodnotu, regulárny výraz, rozsah,
pole alebo lambdu.

## Server

```bash
edupage server            # REST na /api/v1, MCP na /mcp
edupage mcp               # MCP cez stdio, pre editory a desktop klientov
```

Počúva na `127.0.0.1` a pri prvom spustení si vygeneruje bearer token do configu.
Všetky trasy sú `GET`, všetky MCP tooly sú označené ako read-only.

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:4567/api/v1/schools/zsdemo/students/Jana/years/2025/grades?term=P1"
```

### Zapojenie MCP

`edupage mcp-add` zaregistruje server u klienta, `edupage mcp-config` iba vypíše
záznam `mcpServers`, ak si ho chceš do configu pridať ručne.

```bash
edupage mcp-add claude-code --scope user    # cez `claude mcp add`
edupage mcp-add claude-desktop              # zlúči sa do claude_desktop_config.json
edupage mcp-add all --scope user            # oboje
edupage mcp-add all --dry-run               # ukáže, čo by spravil, nezmení nič
edupage mcp-add all --http                  # zaregistruje HTTP endpoint namiesto stdio

edupage mcp-config                          # len JSON a nič iné
edupage mcp-config --http
```

Pridávanie je **idempotentné**: zhodný záznam ponechá, odlišný upraví a chýbajúci
doplní. Config Claude Desktopu sa zlučuje, nie prepisuje - ostatné servery aj nesúvisiace
nastavenia zostanú - a predošlá verzia sa odloží ako `.bak`.

Pre lokálny nástroj je lepšie predvolené stdio: proces spravuje klient, takže netreba
riešiť autentifikáciu ani udržiavať server v chode. `--http` sa pripája na `/mcp`
spusteného `edupage server` a posiela token v hlavičke `Authorization`, čo sa hodí, keď
jeden proces zdieľa viac klientov.

Ani jeden variant nenastavuje školu ani študenta napevno - sú to úrovne hierarchie
a model si ich má zvoliť pri každom volaní.

Vygenerovaný stdio záznam používa absolútne cesty a pri behu z checkoutu nastavuje
`BUNDLE_GEMFILE`, lebo MCP klienti spúšťajú servery z vlastného pracovného adresára.
Pri inštalácii cez Homebrew ukazuje na `$(brew --prefix)/opt/edupage-cli/bin/edupage`,
nie na verziovanú cestu v `Cellar`, takže záznam zostane platný aj po `brew upgrade`. Zariaďuje to
premenná `EDUPAGE_EXECUTABLE`, ktorú nastavuje wrapper z formuly; rovnako ju môže
použiť akýkoľvek iný balíčkovač. MCP klienti navyše spúšťajú servery aj **bez
nastaveného locale**, preto každý súbor otvárame výslovne ako UTF-8 a nespoliehame sa
na `Encoding.default_external`.

## Ako udržiavame rozhrania v súlade

Zdroje sú deklarované na jednom mieste, v `lib/edupage/registry/resources.rb`:

```ruby
resource :grades do
  scope   :year
  summary "Grades for a school year"
  param   :term, type: :enum, values: %w[P1 P2], desc: "Half-year"
  resolve ->(year, p) { year.grades.where(term: p[:term]) }
end
```

Z toho sa vygeneruje CLI príkaz, REST trasa aj MCP tool a `spec/registry_parity_spec.rb`
spadne, ak niektorý z nich chýba alebo má odlišné parametre. Výstup `--json`, telo REST
odpovede aj výsledok MCP toolu idú cez jeden serializer, takže sú bajt na bajt zhodné.

`scope` zároveň určuje, ktoré úrovne hierarchie zdroj vyžaduje, a všetky tri rozhrania
ich vyžadujú rovnako: v REST sú súčasťou cesty, vstupná schéma MCP ich označí ako povinné
a CLI príkaz bez nich odmietne a vypíše zoznam možností.

## Poznámky k samotnému Edupage

Veci, ktoré stojí za to vedieť - všetky overené na živom účte:

- **Jedným účtom sa dá prihlásiť do viacerých škôl.** `mauth` vráti jednu session na
  každú školu.
- **Session drží aktuálne dieťa a aktuálny školský rok.** Prepnutie dieťaťa aj roka mení
  zdieľaný stav na serveri, preto prebieha pod súborovým zámkom a pri každej odpovedi sa
  overuje, či zodpovedá požadovanému dieťaťu a roku.
- **Prepnutie sa prejaví s oneskorením.** Edupage prepnutie potvrdí okamžite, ale ešte
  request alebo dva vracia stránku predošlého dieťaťa či roka, takže sa fetch opakuje,
  kým stránka nesedí. Ak by sa vrátila neaktuálna stránka, dostal by si bez upozornenia
  rozvrh iného dieťaťa.
- **Číselníky sa medzi rokmi menia.** Zoznam tried za 2025 nie je ten istý ako za 2026,
  preto je rok súčasťou každého cache kľúča.
- **Timeline je spoločná pre všetky deti rodiča** a delí sa lokálne podľa mapy
  `childGroups`.
- **Domáce úlohy sa zadávajú buď celej triede, alebo jednotlivým žiakom.** Treba
  podporovať oba prípady: na účte, na ktorom to vzniklo, je 15 zo 16 úloh jedného
  dieťaťa zadaných individuálne.

## Vývoj

```bash
bundle exec rspec
```

Testy používajú ručne pripravené payloady, nie uložené stránky: tie skutočné
majú stovky kilobajtov a sú v nich mená cudzích detí.

Keby predsa len vznikla VCR kazeta, `spec/support/cassette_scrubber.rb` z nej pred
zápisom na disk odstráni osobné údaje - mená, názvy škôl, subdomény aj e-maily, a to
v tele odpovede, v URI aj v hlavičkách. Mená neberie z pevného zoznamu, ale **priamo
z odpovede** - z polí, kam ich Edupage vždy dáva - a potom nahradí každý ich výskyt vrátane
tých vo voľnom texte správ. Pseudonym je odvodený z pôvodnej hodnoty, takže ten istý
človek má v každej kazete rovnaký pseudonym a vzájomné odkazy v payloade zostanú
platné; pôvodnú hodnotu sa z pseudonymu spätne získať nedá. Keďže slovenčina skloňuje, hľadá sa aj
kmeň mena, takže zmiznú aj tvary ako `Janu` či `Kováčovej`, nielen základný tvar.

Overiť sa to dá proti živému účtu:

```bash
EDUPAGE_LIVE_USERNAME=you@example.com EDUPAGE_LIVE_SCHOOL=yourschool \
  bundle exec rspec spec/live_recording_spec.rb --tag live
```

Ten test si zoznam mien, ktoré sa v kazete nesmú objaviť, **načíta zo živého účtu**, nie
z ručne napísaného zoznamu - spadne teda aj vtedy, keď pribudne spolužiak alebo druhá
škola, ktorú scrubber nevie nájsť. Zároveň kontroluje, že sa kazeta uložila ako čitateľný
text: Edupage posiela stránky gzipnuté a kontrola mien by v komprimovanom tele nič
nenašla, hoci by v ňom všetky mená zostali.

CI beží na Ruby 3.2, 3.3 a 3.4 na Linuxe, plus jeden macOS job, ktorý si vytvorí vlastný
odomknutý keychain, aby sa keychain testy naozaj spustili a nepreskočili.

### Vydanie

Vydanie spustí zmena `Edupage::VERSION` v `lib/edupage/version.rb`. Keď CI na `main`
prejde, release workflow pushne gem na rubygems.org, vytvorí tag a GitHub release
a nakoniec aktualizuje formulu v tape
[alhafoudh/homebrew-edupage](https://github.com/alhafoudh/homebrew-edupage) na nový tag
(cez deploy key v secrete `HOMEBREW_TAP_DEPLOY_KEY`). Tap má vlastné CI, ktoré formulu
postaví a otestuje na macOS (arm64, Intel) aj Linuxe (x64, arm64). Každý krok je
idempotentný, takže zlyhaný beh stačí spustiť znova.

## Rozsah

Zámerne iba na čítanie. Do Edupage sa nič nezapisuje - žiadne odpovede na správy, žiadne
označovanie úloh za hotové, žiadne podpisovanie známok. `spec/registry_parity_spec.rb`
aj samostatný CI job overujú, že sa v `lib/` neobjaví write endpoint.
