#!/bin/zsh
# Opens each URL in Chrome and logs which site Moji sees and whether it stays off. Types nothing.
for url in "$@"; do
  open -a "Google Chrome" "$url"; sleep 4
  pkill -x Moji; sleep 0.5
  open -a "/Applications/Moji Picker.app" --args --host-probe; sleep 4
  grep host-probe ~/Library/Logs/Moji.log | tail -1
done
pkill -x Moji; open "/Applications/Moji Picker.app"
