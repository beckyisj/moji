#!/bin/zsh
# Runs Moji's self-test against the frontmost test app. Usage: selftest.sh <bundle-id-to-front> <out-file>
pkill -x Moji; sleep 0.5
osascript -e "tell application id \"$1\" to activate"
echo "Waiting for $1 to be in front (click into its text field)…"
for i in {1..60}; do
  [[ "$(lsappinfo info -only bundleid "$(lsappinfo front)")" == *"\"$1\""* ]] && break
  sleep 0.5
done
sleep 1
rm -f "$2"
open -a "/Applications/Moji Picker.app" --args --selftest "$2"
for i in {1..120}; do [[ -f "$2" ]] && break; sleep 1; done
tail -1 ~/Library/Logs/Moji.log
cat "$2" 2>/dev/null || echo "no output"
