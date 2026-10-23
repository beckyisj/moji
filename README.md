# Moji

A native macOS emoji picker with smarter search. Type `:` and a couple of letters in any app, then pick with ↑ ↓ and ↩ or ⇥. Typing the closing colon on an exact shortcode (`:tada:`) swaps it in straight away.

## Why it's better

Search runs entirely on your Mac, with no API calls. Layers, strongest first:

- **Shortcodes**: Slack and GitHub shortcodes (`:+1:`, `:tada:`)
- **Names and keywords**: CLDR emoji names and keywords
- **Chat slang**: `lol` → 😂, `lgtm` → 👍, `yay` → 🎉, `grr` → 😤
- **Typo tolerance**: `thmbs` → 👍
- **Related words**: Apple's on-device word embeddings, so `woohoo` → 🎉, and `doggo` backs off to 🐶
- **Popularity and frecency**: common emoji rank first, and the ones you pick float up over time

It stays out of the way:

- **Not in the middle of a word:** `:` only triggers after a space, punctuation or the start of a field, so `10:30`, `https:` and `:D` are left alone.
- **Off where there's already a picker:** apps with their own `:` picker (Slack, Discord, Notion, Telegram, WhatsApp, Figma, Roam, Teams, Linear), terminals and code editors, and browser tabs on those web apps (Slack, GitHub, Linear, Notion and more).
- **Menu bar controls:** turn it on or off, switch it off for the current app, set a skin tone, choose when suggestions appear, and open at login.

## Install

Requires macOS 14+ and Xcode (for the Swift toolchain and signing).

```bash
./scripts/bundle.sh       # builds and installs /Applications/Moji Picker.app
```

Then allow **Moji Picker** in System Settings → Privacy & Security → Accessibility. It needs that permission to see what you type and to insert emoji.

**Signing:** `bundle.sh` signs with your **Apple Development** certificate if you have one (Xcode → Settings → Accounts → Manage Certificates). With it, the Accessibility grant survives rebuilds. Without it the app is ad-hoc signed and you'll need to re-grant after each build. Self-signed certificates don't work for Accessibility on macOS 26. If you don't have Apple's WWDR G3 intermediate certificate, Xcode can't use your certificate. Download it from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/).

## Develop

```bash
swift run moji-search lol yay thmbs woohoo    # see the ranking from the terminal
./scripts/fetch-data.sh && python3 scripts/build-data.py   # rebuild Resources/emoji.json
```

The emoji data merges [emojibase](https://emojibase.dev) (labels, keywords, skin tones), its iamcal Slack shortcodes, and [gemoji](https://github.com/github/gemoji) (GitHub aliases). All three are MIT licensed.

### Self-test

`./scripts/selftest.sh <bundle-id> <absolute-output-path>` has Moji type 14 phrases as real keystrokes into the front app's text field, read the result back, and write pass/fail lines. It only types when TextEdit, Safari or Chrome is in front. Run it from Terminal, and leave the mouse and keyboard alone while it runs. Test pages are in `test/` (`github.html` checks the web-app exclusion).

```bash
open -a Safari test/field.html
./scripts/selftest.sh com.apple.Safari "$PWD/build/selftest-safari.txt"
```

## License

MIT
