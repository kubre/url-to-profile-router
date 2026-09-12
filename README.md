# URL to Profile Router

URL to Profile Router is a small macOS utility that routes web links to browser profiles.

## Install from GitHub Releases

1. Download `URL-to-Profile-Router-<version>.zip` or `URL-to-Profile-Router-<version>.dmg`.
2. Open the downloaded file.
3. If you use the ZIP:
   - unzip it.
   - run `./install-url-to-profile-router.command` from a terminal in the extracted folder.
4. If you use the DMG:
   - open it.
   - run `./install-url-to-profile-router.command` inside the mounted volume.
5. The installer writes `~/.config/url-router.conf` if missing and then opens the app.
6. Set it as default:
   - in app menu: **Set as Default Browser**
   - or run:

```sh
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --set-default
```

## Set it as your default browser

1. Open **URL to Profile Router**.
2. Click **Set as Default Browser** from the menu bar icon menu.
3. Confirm the alert.
4. Optional CLI check:

```sh
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --set-default
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --check
```

## If the app is blocked / not trusted

If macOS shows a security warning:

1. Open **System Settings** → **Privacy & Security**.
2. In **Security**, find this app and click **Open Anyway**.
3. Open the app again.

If you still see a block, run:

```sh
xattr -dr com.apple.quarantine "/Applications/URL to Profile Router.app"
open -a "URL to Profile Router"
```

## Build one install file locally

For easy sharing, build release files directly into `~/Documents/scrcap`:

```sh
./release-package.sh
```

This creates:

- `~/Documents/scrcap/URL-to-Profile-Router-<version>.zip`
- `~/Documents/scrcap/URL-to-Profile-Router-<version>.dmg`

For each release package:

- `URL-to-Profile-Router-<version>.zip` / `.dmg` contains:
  - `URL to Profile Router.app`
  - `install-url-to-profile-router.command`
  - `url-router.conf` (generic starter config)

## Rules

Rules are stored at `~/.config/url-router.conf` (auto-created on first run).

If the file is empty or only comments, links stay in the browser fallback.

```text
# URL to Profile Router
#
# This file controls how links are routed.
#
# How rules are applied:
# - Rules are read from top to bottom.
# - First match wins.
# - Domain rules match the host and all subdomains.
# - Blank lines and lines starting with # are ignored.
#
# Supported directives:
#   @browser <browser-bundle-id>
#   @fallback <profile-name>
#   <domain> <profile-name>
#
# Optional browser override:
# Set one browser for every request handled by this file.
# @browser com.google.Chrome
#
# Optional fallback profile:
# Used when no domain rule matches.
# @fallback Personal
#
# Example:
# @browser com.google.Chrome
# @fallback Personal
# github.com Work
# docs.google.com Work
# youtube.com Personal
#
# Keep profile names exactly as they appear in your browser.
```

Supported browser bundle IDs can include Helium, Chrome, Chromium, Brave, Edge, Vivaldi, and others available on macOS.
Profile names must exist in the target browser. Local `file://` URLs use the browser’s last-used profile.

Useful checks:

```sh
APP="/Applications/URL to Profile Router.app/Contents/MacOS/Router"
"$APP" --check
"$APP" --list-profiles
"$APP" --dry-run https://github.com/foo
```

## Publish a new release

For maintainers:

1. Build local release files:

```sh
./release-package.sh ./release v1.0.0
```

2. Create or update the GitHub release using `gh`:

```sh
gh release create v1.0.0 \
  ./release/URL-to-Profile-Router-v1.0.0.zip \
  ./release/URL-to-Profile-Router-v1.0.0.dmg \
  --generate-notes
```

Use `--notes`, `--title`, `--prerelease`, `--draft`, `--verify-tag`, or `--latest=false` when needed.

If the release already exists:

```sh
gh release upload v1.0.0 \
  ./release/URL-to-Profile-Router-v1.0.0.zip \
  ./release/URL-to-Profile-Router-v1.0.0.dmg \
  --clobber
```

`gh release --help` and `gh release create --help` show more options.
