#!/usr/bin/env bash
# Extract everything readable from a strategy video (no speech model needed):
#   1) a contact sheet of frames (to see the drawings: levels, zones, arrows, ENTRY marks)
#   2) the burned-in captions / on-screen text, read with Tesseract (Arabic + English), duplicates removed
# Usage: extract_video.sh VIDEO OUT_DIR
set -euo pipefail
v="$1"; out="$2"
mkdir -p "$out/frames"; rm -f "$out"/frames/*.png
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$v")
echo "duration: ${dur}s"
# one picture every ~duration/12 s → 4x3 sheet
step=$(python3 -c "print(max(1.0, float('$dur')/12))")
ffmpeg -v error -y -i "$v" -vf "fps=1/$step,scale=360:-1,tile=4x3" -frames:v 1 "$out/sheet.jpg"
# text: 3 frames per second, keep a line only when it changes
ffmpeg -v error -i "$v" -vf "fps=3" "$out/frames/%04d.png"
prev=""
: > "$out/text.txt"
for p in "$out"/frames/*.png; do
  t=$(tesseract "$p" stdout --psm 11 -l ara+eng 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//')
  if [ "$t" != "$prev" ]; then
    n=$(basename "$p" .png); sec=$(python3 -c "print(f'{(int(\"$n\")-1)/3:.1f}')")
    echo "${sec}s: $t" >> "$out/text.txt"; prev="$t"
  fi
done
echo "sheet: $out/sheet.jpg"; echo "text:  $out/text.txt ($(wc -l < "$out/text.txt") changes)"
