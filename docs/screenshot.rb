# Regenerates docs/screenshot.png: a staged edupage session with made-up data
# (no real pupils), drawn by the real table renderer and screenshotted in a fake
# terminal window by headless Chrome.
#
#   bundle exec ruby -I lib docs/screenshot.rb
#
# Needs Google Chrome (override the binary with CHROME=...) and looks best with
# the CaskaydiaCove Nerd Font installed; it falls back to Menlo. Chrome writes
# no metadata chunks, so the PNG is safe to publish as is.

require "cgi"
require "tmpdir"
require "edupage"

OUTPUT = File.expand_path("screenshot.png", __dir__)
CHROME = ENV.fetch("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
TABLE_WIDTH = 78
# Canvas size in CSS pixels, rendered at 2x. Leaves about 40px around the window.
CANVAS = [790, 476].freeze

COLORS = { 32 => "#a6e3a1", 33 => "#f9e2af", 35 => "#cba6f7", 36 => "#89dceb", 37 => "#cdd6f4" }.freeze

def paint(text, code) = "\e[#{code}m#{text}\e[0m"

def session
  out = +""
  prompt = ->(command) { out << paint("$ ", "1;35") << paint("edupage", "1;36") << " " << paint(command, "37") << "\n" }
  context = ->(pairs) { pairs.each { |key, value| out << paint("#{key.ljust(8)}: ", "2") << value << "\n" } }
  table = ->(headers, rows) { out << Edupage::CLI::Table.boxed(headers, rows, width: TABLE_WIDTH) << "\n" }

  prompt.("grades --student Ema --term P1")
  context.("student" => "Ema Nováková (4.A)", "year" => "2026/2027")
  table.(["created at", "subject", "value", "title"],
         [["2026-09-10", "Matematika", paint("1", "1;32"), "Vstupná písomná práca"],
          ["2026-09-18", "Anglický jazyk", paint("1", "1;32"), "Slovíčka - Unit 1"],
          ["2026-09-25", "Slovenský jazyk", paint("2", "1;33"), "Diktát - vybrané slová"],
          ["2026-10-02", "Prírodoveda", paint("95%", "1;32"), "Rastliny a živočíchy"]])
  out << "\n"

  prompt.("mcp-add claude-code")
  out << paint("✓", "1;32") << " Registered " << paint("edupage", "1;36") << " MCP server in Claude Code\n"
  out << paint("  Ask Claude: \"Čo má Ema zajtra za úlohy?\"", "2")
end

def to_html(ansi)
  style = {}
  ansi.split(/(\e\[[\d;]*m)/).map do |part|
    if (codes = part[/\A\e\[([\d;]*)m\z/, 1])
      codes.split(";").map(&:to_i).each do |code|
        case code
        when 0 then style = {}
        when 1 then style[:bold] = true
        when 2 then style[:dim] = true
        else style[:color] = COLORS[code]
        end
      end
      ""
    else
      css = []
      css << "color:#{style[:color]}" if style[:color]
      css << "font-weight:700" if style[:bold]
      css << "opacity:.5" if style[:dim]
      text = CGI.escapeHTML(part)
      css.empty? ? text : %(<span style="#{css.join(";")}">#{text}</span>)
    end
  end.join
end

def page(body)
  <<~HTML
    <!doctype html>
    <html><head><meta charset="utf-8"><style>
      html, body { margin: 0; }
      body {
        width: #{CANVAS[0]}px; height: #{CANVAS[1]}px; display: flex; align-items: center; justify-content: center;
        background: radial-gradient(circle at 20% 15%, #6d5bd0 0%, transparent 45%),
                    radial-gradient(circle at 85% 90%, #1f9e89 0%, transparent 50%), #1b1830;
        font-family: "CaskaydiaCove Nerd Font Mono", "CaskaydiaCove Nerd Font", Menlo, monospace;
      }
      .window {
        background: #1e1e2e; border-radius: 14px; overflow: hidden;
        box-shadow: 0 30px 80px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.08);
      }
      .bar { height: 40px; background: #181825; display: flex; align-items: center; padding: 0 16px; position: relative; }
      .dot { width: 13px; height: 13px; border-radius: 50%; margin-right: 8px; }
      .title { position: absolute; left: 0; right: 0; text-align: center; color: #7f849c; font-size: 14px; }
      pre { margin: 0; padding: 22px 30px 28px; color: #cdd6f4; font: inherit; font-size: 17px; line-height: 1.2; }
    </style></head><body>
      <div class="window">
        <div class="bar">
          <div class="dot" style="background:#ff5f57"></div>
          <div class="dot" style="background:#febc2e"></div>
          <div class="dot" style="background:#28c840"></div>
          <div class="title">edupage - bash</div>
        </div>
        <pre>#{body}</pre>
      </div>
    </body></html>
  HTML
end

Dir.mktmpdir do |dir|
  html = File.join(dir, "screenshot.html")
  File.write(html, page(to_html(session)))
  system(CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
         "--window-size=#{CANVAS.join(",")}", "--screenshot=#{OUTPUT}", "file://#{html}",
         err: File::NULL, exception: true)
end

puts "Wrote #{OUTPUT}"
