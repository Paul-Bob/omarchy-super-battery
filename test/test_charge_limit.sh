#!/bin/bash
# Runs bin/charge-limit against fake power_supply trees. No root, no sysfs.
set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/bin/charge-limit"
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

run() { SUPER_BATTERY_SYSFS="$1" "$script" "${@:2}" 2>&1; }

# A Legion-style laptop: conservation mode only, plus a mouse battery and AC.
legion=$(mktemp -d)
mkdir -p "$legion/ADP0" "$legion/BAT0" "$legion/hidpp_battery_0"
echo Mains >"$legion/ADP0/type"
echo Battery >"$legion/BAT0/type"
echo "Fast [Standard] Long_Life" >"$legion/BAT0/charge_types"
echo Battery >"$legion/hidpp_battery_0/type"

check "conservation laptop: status" $'kind\ttypes\nvalue\tStandard\nwritable\t1\nbattery\tBAT0' "$(run "$legion" status)"
run "$legion" set Long_Life >/dev/null
check "conservation laptop: set Long_Life writes the mode" "Long_Life" "$(<"$legion/BAT0/charge_types")"
check "conservation laptop: a number is refused" "charge-limit: mode must be Long_Life or Standard, got '80'" "$(run "$legion" set 80)"

# Real sysfs reads back in the bracketed form; the fake file does not.
echo "Fast Standard [Long_Life]" >"$legion/BAT0/charge_types"
check "conservation laptop: status reads the bracketed mode" "Long_Life" "$(run "$legion" status | awk -F'\t' '$1=="value"{print $2}')"
chmod a-w "$legion/BAT0/charge_types"
check "not writable yet: status says so" "0" "$(run "$legion" status | awk -F'\t' '$1=="writable"{print $2}')"
check "not writable yet: set explains the setup" "charge-limit: not writable yet: run the one-time setup" "$(run "$legion" set Standard)"
chmod -R u+w "$legion"; rm -rf "$legion"

# A ThinkPad-style laptop with a numeric threshold (and charge_types too).
thinkpad=$(mktemp -d)
mkdir -p "$thinkpad/BAT0"
echo Battery >"$thinkpad/BAT0/type"
echo 100 >"$thinkpad/BAT0/charge_control_end_threshold"
echo "[Standard] Long_Life" >"$thinkpad/BAT0/charge_types"

check "threshold laptop: the number wins over charge_types" $'kind\tthreshold\nvalue\t100\nwritable\t1\nbattery\tBAT0' "$(run "$thinkpad" status)"
run "$thinkpad" set 80 >/dev/null
check "threshold laptop: set 80" "80" "$(<"$thinkpad/BAT0/charge_control_end_threshold")"
check "threshold laptop: out of range is refused" "charge-limit: limit must be 50-100, got '20'" "$(run "$thinkpad" set 20)"
check "threshold laptop: junk is refused" "charge-limit: limit must be 50-100, got '8;0'" "$(run "$thinkpad" set '8;0')"
rm -rf "$thinkpad"

# charge_types without Long_Life, and no battery at all.
other=$(mktemp -d)
mkdir -p "$other/BAT1"
echo Battery >"$other/BAT1/type"
echo "[Standard] Fast" >"$other/BAT1/charge_types"
check "charge_types without Long_Life: unsupported" $'kind\tnone' "$(run "$other" status)"
check "unsupported: set refuses" "charge-limit: this laptop has no charge limit control" "$(run "$other" set Long_Life)"
rm -rf "$other"

empty=$(mktemp -d)
check "desktop with no battery: unsupported" $'kind\tnone' "$(run "$empty" status)"
rm -rf "$empty"

(( failures == 0 )) && echo "ALL PASS" || { echo "$failures FAILED"; exit 1; }
