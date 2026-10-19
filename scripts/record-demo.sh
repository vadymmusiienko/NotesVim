#!/bin/bash
# Records docs/demo.gif for the README: Notes driven with real key presses, with captions.
#
# Only a "NotesVim Demo" folder with three made-up notes is ever on screen. It is created (or
# reset) here. NotesVim must be running with the Accessibility permission, and the terminal
# needs Accessibility and Screen Recording access. Takes about 40 seconds; don't touch anything.
set -euo pipefail
cd "$(dirname "$0")/.."

osascript <<'APPLESCRIPT'
tell application "Notes"
  if not (exists folder "NotesVim Demo") then make new folder with properties {name:"NotesVim Demo"}
  set demo to folder "NotesVim Demo"
  set demoNotes to {¬
    {"Weekend trip", "<div><h1>Weekend trip</h1></div><div>Pack light, the forecast says sun.</div><div>Train leaves at nine on Saturday.</div><div>Book a table for dinner by the lake.</div><div>Bring the old camera and two films.</div>"}, ¬
    {"Book ideas", "<div><h1>Book ideas</h1></div><div>A lighthouse keeper who collects letters.</div><div>Two rival bakers in a small town.</div><div>A map that redraws itself every night.</div>"}, ¬
    {"Groceries", "<div><h1>Groceries</h1></div><div>Apples</div><div>Coffee beans</div><div>Fresh basil</div><div>Sourdough bread</div>"}}
  repeat with item_ in demoNotes
    set noteName to item 1 of item_
    if exists note noteName of demo then
      set body of note noteName of demo to item 2 of item_
    else
      make new note at demo with properties {body:item 2 of item_}
    end if
  end repeat
  activate
  show demo
  delay 0.8
  show note "Weekend trip" of demo
end tell
APPLESCRIPT
sleep 1.5

WORK="$(mktemp -d)"
trap 'command rm -rf "$WORK"' EXIT
swiftc -O scripts/demo/DemoDriver.swift -o "$WORK/demo-driver"
"$WORK/demo-driver" "$WORK/demo.mov"

# 1.5 pixels per point keeps the small Notes text readable once GitHub scales the GIF down.
ffmpeg -loglevel error -y -i "$WORK/demo.mov" \
  -vf "fps=15,scale=990:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  docs/demo.gif
echo "Wrote docs/demo.gif ($(du -h docs/demo.gif | cut -f1))"
