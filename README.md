# url-to-profile-router

Tiny Velja/Choosy clone. One Swift file, no dependencies. Routes URLs to Helium profiles.

- `github.com` → Helium profile `tars`
- `youtube.com`, `youtu.be` → Helium profile `persoanl`
- everything else → Helium default (last used profile)

Edit rules in `~/.config/url-router.json` (created on first run from `rules.json`).

## Build

```
./build.sh
```

Makes `build/Router.app`.

## Install

1. Copy `build/Router.app` to `/Applications`.
2. System Settings → Desktop & Dock → Default web browser → Router.
3. Click a link. Done.

CLI for testing:

```
./build/Router.app/Contents/MacOS/Router --dry-run https://github.com/foo
./build/Router.app/Contents/MacOS/Router --list-profiles
./build/Router.app/Contents/MacOS/Router --set-default
```

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
