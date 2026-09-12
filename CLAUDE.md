# edupage-cli

Ruby CLI + ActiveRecord-like knižnica nad neoficiálnym Edupage API (scraping session-based
webu). Read-only.

Obsidian tracking: no

## Prostredie

Credentials sú v `mise.toml` (`EDUPAGE_SCHOOL`, `EDUPAGE_USERNAME`, `EDUPAGE_PASSWORD`,
ťahané z 1Password). Príkazy spúšťaj cez `mise exec -- ...`, inak env chýba.

## Tvrdé pravidlá

- Iba read-only operácie proti Edupage. Nikdy nič nezapisuj do produkčného účtu
  (žiadne createItem, createReply, homeworkFlag, podpisovanie známok).
- Testy bežia cez rspec + VCR. Kazety musia mať odfiltrované `PHPSESSID`/`esid`,
  heslo a username.
