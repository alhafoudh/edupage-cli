# Small stand-ins shaped like the real Edupage payloads.
#
# Handcrafted rather than recorded: the real pages are 200-400 KB and carry the names of
# 40-odd other people's children, which has no place in a repository. Every field here
# was copied from a live response, only the values are invented.
module Payloads
  module_function

  def dbi
    {
      "students" => {
        "-77" => { "id" => "-77", "classid" => "-2", "firstname" => "Peter",
                   "lastname" => "Novák", "parent1id" => "-1", "gender" => "M",
                   "numberinclass" => "1", "isOut" => false },
        "113506" => { "id" => "113506", "classid" => "117967", "firstname" => "Jana",
                      "lastname" => "Nováková", "parent1id" => "-1", "gender" => "F",
                      "numberinclass" => "3", "isOut" => false },
        "999" => { "id" => "999", "classid" => "117967", "firstname" => "Iný",
                   "lastname" => "Žiak", "gender" => "M", "numberinclass" => "4" }
      },
      "teachers" => {
        "37135" => { "id" => "37135", "firstname" => "Anna", "lastname" => "Kováčová",
                     "short" => "Gl", "nameprefix" => "Mgr. ", "namesuffix" => "",
                     "classroomid" => "", "cb_hidden" => 0 },
        "120227" => { "id" => "120227", "firstname" => "Dominika", "lastname" => "Horváthová",
                      "short" => "Kp", "nameprefix" => "", "namesuffix" => "PhD.",
                      "classroomid" => "37260", "cb_hidden" => 0 }
      },
      "parents" => {
        "-1" => { "id" => "-1", "firstname" => "Ahmed", "lastname" => "Novák", "gender" => "M" }
      },
      "classes" => {
        "-2" => { "id" => "-2", "name" => "2.A", "short" => "2.A", "grade" => "2",
                  "teacherid" => "37135", "classroomid" => "" },
        "117967" => { "id" => "117967", "name" => "4.A", "short" => "4.A", "grade" => "4",
                      "teacherid" => "120227", "classroomid" => "37260" }
      },
      "classrooms" => {
        "37260" => { "id" => "37260", "name" => "4A", "short" => "4A", "cb_hidden" => false },
        "35599" => { "id" => "35599", "name" => "1. poschodie", "short" => "1.p", "cb_hidden" => true }
      },
      "subjects" => {
        "34478" => { "id" => "34478", "name" => "Slovenský jazyk a literatúra", "short" => "SJL" },
        "34482" => { "id" => "34482", "name" => "Matematika", "short" => "MAT" }
      },
      # Periods arrive as an array while everything else is keyed by id.
      "periods" => [
        { "id" => "1", "name" => "1", "short" => "1", "starttime" => "07:50", "endtime" => "08:35" },
        { "id" => "2", "name" => "2", "short" => "2", "starttime" => "08:45", "endtime" => "09:30" }
      ]
    }
  end

  def lesson(period: "1", subject: "34478", teacher: "120227", room: "37260")
    {
      "type" => "lesson", "uniperiod" => period, "period" => period,
      "subjectid" => subject, "teacherids" => [teacher], "classroomids" => [room],
      "classids" => ["117967"], "groupnames" => [""], "lid" => "abc",
      "starttime" => "07:50", "endtime" => "08:35",
      "infos" => [{ "type" => "wd", "texts" => [{ "text" => "Učivo: Opakovanie" }] }]
    }
  end

  def empty_period(period: "0")
    { "type" => "period", "uniperiod" => period, "period" => period,
      "header" => [], "classids" => [], "teacherids" => [], "classroomids" => [],
      "groupnames" => [] }
  end

  # The dashboard always carries "today" plus the next few days, so the fixture follows
  # the clock rather than pinning a date that quietly stops being today.
  def today = Date.today.iso8601

  def userhome(child: "113506", year: "2026", items: [])
    {
      "userid" => "Rodic-1",
      "userrow" => { "UserID" => "Rodic-1", "p_meno" => "Ahmed", "p_priezvisko" => "Novák",
                     "p_www_login" => "parent@example.com", "p_mail" => "parent@example.com" },
      "dbi" => dbi,
      "dp" => {
        "dates" => {
          today => {
            "tt_num" => 79, "tt_day" => 4, "tt_week" => 0, "tt_term" => 0,
            "student_absents" => [],
            "plan" => [empty_period, lesson, lesson(period: "2", subject: "34482")]
          }
        }
      },
      "items" => items,
      "childGroups" => {
        "-77" => ["Student-77", "Trieda-2", "CustPlan8503"],
        "113506" => ["Student113506", "Trieda117967", "CustPlan8562"]
      },
      "parentStudentids" => [-77, 113_506],
      "loggedChild" => child.to_i,
      "selectedYear" => year.to_i
    }
  end

  # Wraps a payload the way Edupage does, so the extraction path is exercised too.
  def userhome_html(**options)
    payload = userhome(**options)
    edubar = {
      "loggedUser" => "Rodic-1", "loggedUserName" => "Ahmed Novák",
      "loggedChild" => payload["loggedChild"],
      "selectedYear" => payload["selectedYear"], "autoYear" => 2026, "edupage" => "zsdemo"
    }

    <<~HTML
      <html><script>
        ASC.edupage = "zsdemo";
        ASC.school_name = "Demo School";
        ASC.gsechash = "abc12345";
        ASC.lang = "sk";
      </script>
      <script>$j('#edubar').edubar(#{JSON.generate(edubar)});</script>
      <script>$j(document).ready(function() { $j('#x').userhome(#{JSON.generate(payload)}); });</script>
      </html>
    HTML
  end

  # A timeline homework item. `recipient` decides whether it reads as a class-wide task
  # or one set to a single pupil - the distinction the whole Assignment model exists for.
  def homework_item(id:, recipient:, title:, subject: "34478", due: "2026-09-14", owner: "Ucitel120227")
    {
      "timelineid" => id,
      "typ" => "homework",
      "user" => recipient,
      "user_meno" => recipient.start_with?("Student") ? "Jana Nováková" : "4.A",
      "vlastnik" => owner,
      "vlastnik_meno" => "Dana Horváthová",
      "text" => "",
      "cas_pridania" => "2026-09-11 08:30:00",
      "cas_udalosti" => nil,
      "reakcia_na" => nil,
      "pocet_reakcii" => "0",
      "removed" => "0",
      "data" => JSON.generate(
        "predmetid" => subject, "triedaid" => "117967", "nazov" => title,
        "popis" => "", "date" => due, "id" => "HW#{id}"
      )
    }
  end

  def message_item(id:, recipient:, text: "Oznam")
    {
      "timelineid" => id, "typ" => "sprava", "user" => recipient,
      "vlastnik" => "Ucitel37135", "vlastnik_meno" => "Mária Kováčová",
      "text" => text, "cas_pridania" => "2026-09-10 12:00:00",
      "pocet_reakcii" => "0", "removed" => "0", "data" => "null"
    }
  end

  # --- grades -------------------------------------------------------------------------

  def znamky(year: "2025", term: "P2", grades: nil, events: nil)
    {
      "studentid" => "113506",
      "yearid" => year,
      "skRok" => "#{year}/#{year.to_i + 1}",
      "nadobdobie" => term,
      "vsetkyZnamky" => grades || [grade_row],
      "vsetkyUdalosti" => { "edupage" => (events || { "3687300" => event_row }) },
      "predmety" => {},
      "yearterms" => [
        { "yearid" => "2025", "yearName" => "2025/2026", "term" => "P2", "termName" => "2. polrok",
          "dateFrom" => "2026-02-01", "dateTo" => "2026-06-30", "numGrades" => "2" },
        { "yearid" => "2025", "yearName" => "2025/2026", "term" => "P1", "termName" => "1. polrok",
          "dateFrom" => "2025-09-01", "dateTo" => "2026-01-31", "numGrades" => "1" },
        { "yearid" => "2026", "yearName" => "2026/2027", "term" => "P1", "termName" => "1. polrok",
          "dateFrom" => "2026-09-01", "dateTo" => "2027-01-31", "numGrades" => "0" }
      ]
    }
  end

  def grade_row(id: "1", value: "1", period: "P2", event: "3687300", subject: "34482")
    { "provider" => "edupage", "znamkaid" => id, "studentid" => "113506",
      "predmetid" => subject, "udalostid" => event, "mesiac" => period, "data" => value,
      "datum" => "2026-01-27 12:10:36", "ucitelid" => "120227",
      "podpisane" => nil, "podpisane_rodic" => "2026-02-03 11:06:37", "stav" => "o" }
  end

  def event_row(id: "3687300", title: "Písomka", type: "1", weight: "20", max_points: nil)
    { "provider" => "edupage", "UdalostID" => id, "p_meno" => title, "p_skratka" => "",
      "p_typ_udalosti" => type, "p_vaha" => weight, "p_vaha_body" => max_points,
      "PredmetID" => "34482", "TriedaID" => "117967", "UcitelID" => "120227",
      "planid" => "7448", "priemer" => "1.50", "Triedy" => ["117967"],
      "p_termin" => "", "moredata" => [] }
  end

  # Sub-period to half-year mapping, as initZnamkovanieSettings reports it.
  def znamky_settings
    {
      "obdobia" => {
        "P1" => { "id" => "P1", "nazov" => "1. polrok", "nadobdobie" => nil, "polrok" => 1 },
        "V1" => { "id" => "V1", "nazov" => "vysvedčenie 1. polrok", "nadobdobie" => "P1", "polrok" => 1 },
        "P2" => { "id" => "P2", "nazov" => "2. polrok", "nadobdobie" => nil, "polrok" => 2 },
        "V2" => { "id" => "V2", "nazov" => "vysvedčenie 2. polrok", "nadobdobie" => "P2", "polrok" => 2 }
      }
    }
  end

  def znamky_html(**options)
    <<~HTML
      <html><script>
        initZnamkovanieSettings(#{JSON.generate(znamky_settings)});
        znamkyStudentViewer(#{JSON.generate(znamky(**options))});
      </script></html>
    HTML
  end
end
