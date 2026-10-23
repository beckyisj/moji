#!/bin/zsh
# Downloads the source emoji datasets into data-src/ (then run scripts/build-data.py).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data-src
curl -sfL -o data-src/gemoji.json "https://cdn.jsdelivr.net/gh/github/gemoji@v4.1.0/db/emoji.json"
curl -sfL -o data-src/emojibase.json "https://cdn.jsdelivr.net/npm/emojibase-data@16.0.3/en/data.json"
curl -sfL -o data-src/iamcal.json "https://cdn.jsdelivr.net/npm/emojibase-data@16.0.3/en/shortcodes/iamcal.json"
echo "Fetched into data-src/"
