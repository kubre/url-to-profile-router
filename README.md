# URL to Profile Router

Tiny Velja/Choosy clone. One Swift file, no dependencies. Routes URLs to Helium profiles.

- `github.com` → Helium profile `tars`
- `youtube.com`, `youtu.be` → Helium profile `persoanl`
- local files, everything else → Helium default (last used profile)

Edit rules in `~/.config/url-router.json` (created on first run from `rules.json`).

## Install

```
./install.sh
```

Then System Settings → Desktop & Dock → Default web browser → **URL to Profile Router**
(look between Microsoft Edge and Safari; fully quit Settings with Cmd+Q first if the list looks stale).

## Add more rules

`~/.config/url-router.json`:

```json
{
  "browser": "net.imput.helium",
  "rules": [{ "host": "figma.com", "profile": "tars" }],
  "fallbackProfile": null
}
```

Match is suffix-based: `figma.com` also matches `www.figma.com`. First match wins.
`fallbackProfile: "tars"` forces all unmatched URLs into that profile instead of Helium default.

## Test without changing your default browser

```
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --dry-run https://github.com/foo
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --list-profiles
```

## Files

- `main.swift` — the whole app
- `Info.plist` — browser registration (http/https/file schemes, public.html)
- `icon.swift` — draws the app icon at build time (repo stays source-only)
- `rules.json` — default config template
- `build.sh` / `install.sh` — build, sign, install, register
