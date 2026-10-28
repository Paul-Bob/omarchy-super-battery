#!/bin/bash
# Runs bin/add-sound with a stand-in for the file chooser. No window opens.
set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/bin/add-sound"
failures=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ $actual == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "     expected: $(printf '%q' "$expected")"
    echo "     actual:   $(printf '%q' "$actual")"
    failures=$((failures + 1))
  fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sounds="$work/sounds"
mkdir -p "$work/music" "$work/other"
printf 'song one' >"$work/music/Song.mp3"
printf 'song two' >"$work/other/Song.mp3"
printf 'loud' >"$work/music/ALARM.WAV"
printf 'text' >"$work/music/notes.txt"

# The stand-in prints whatever $work/pick holds and exits with $work/status.
cat >"$work/picker" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >"$work/args"
cat "$work/pick" 2>/dev/null
exit \$(cat "$work/status" 2>/dev/null || echo 0)
EOF
chmod +x "$work/picker"

pick() { printf '%s' "$1" >"$work/pick"; echo "${2:-0}" >"$work/status"; }
run() { SUPER_BATTERY_FILE_SELECT="$work/picker" "$script" "$sounds" "Choose a sound for Critical" 2>&1; echo "exit $?"; }

pick "$work/music/Song.mp3"
check "copies the picked file into the sound folder" "$sounds/Song.mp3"$'\n'"exit 0" "$(run)"
check "the copy has the file's contents" "song one" "$(<"$sounds/Song.mp3")"
check "asks the chooser for sound files only, with the title" "--title Choose a sound for Critical --extensions oga ogg wav flac mp3 opus" "$(<"$work/args")"
check "the same file picked again reuses the copy" "$sounds/Song.mp3"$'\n'"exit 0" "$(run)"

pick "$work/other/Song.mp3"
check "a different file with the same name gets a new name" "$sounds/Song-2.mp3"$'\n'"exit 0" "$(run)"
check "the first copy is left alone" "song one" "$(<"$sounds/Song.mp3")"

pick "$sounds/Song-2.mp3"
check "a file already in the sound folder is used where it is" "$sounds/Song-2.mp3"$'\n'"exit 0" "$(run)"

pick "$work/music/ALARM.WAV"
check "upper-case extensions are accepted" "$sounds/ALARM.WAV"$'\n'"exit 0" "$(run)"

pick "" 1
check "cancelling the chooser changes nothing" "exit 1" "$(run)"

pick "" 2
check "a chooser that fails is reported" "The file chooser did not open"$'\n'"exit 2" "$(run)"

pick "$work/music/notes.txt"
check "a file that is not a sound is refused" "Not a sound file Super Battery can play: notes.txt"$'\n'"exit 2" "$(run)"

pick "$work/music/gone.ogg"
check "a file that vanished is reported" "File not found: $work/music/gone.ogg"$'\n'"exit 2" "$(run)"

check "nothing else landed in the sound folder" "ALARM.WAV Song-2.mp3 Song.mp3" "$(ls "$sounds" | tr '\n' ' ' | sed 's/ $//')"

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
