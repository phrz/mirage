# Mirage: notes for agents

## UI rules (from phrz)

The UI should be self-evident, like Apple's own apps. Text earns its place only when the interface can't say it.

- No eyebrows (small labels above headings), no subtitles that restate the heading, and no explanatory or helper text
  unless it's truly necessary to act correctly. Prefer a clear control label over a sentence explaining it.
- Show status only when it's informative. The normal state stays quiet: no "Seen just now", "Connected", "Up to date"
  lines on a healthy row; show "Not reachable" or "Last seen 3 hours ago" when something is off.
- No middle dots (·) joining fragments of text; they read as generated filler.
- Something is either important enough for an alert or it is not said at all. No footer, banner or passing note text
  for routine outcomes or internal details (health checks, deferred probes, retries). Progress of an action the person
  started shows in place (a spinner or progress on the row or button), and success is the state simply changing.
- Wording must never alarm or mislead: say what the person would recognise ("Updating mac-daddy…"), not internal steps
  that sound like something else ("mac-daddy is restarting" reads as a forced reboot).
- Detail lives in secondary places (Get Info as a small AppKit window on Mac, a sheet on iOS), not in list rows.
- Use the platform's own names and wording: System Settings pane names as this macOS calls them, biometry names from
  LocalAuthentication (Touch ID / Face ID / Optic ID), SF Symbols for icons.
- Selected-row states invert like system lists (for example a badge becomes a white cutout on the accent color).
