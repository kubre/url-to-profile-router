# URL to Profile Router

Tiny native macOS URL router. No dependencies. Sends domains to existing Chromium profiles.

## Install

```sh
./install.sh
```

Then select **URL to Profile Router** as the default browser in System Settings.

Rules live at `~/.config/url-router.conf` and are created on first use:

```text
# domain profile — first match wins; subdomains match too
github.com tars
youtube.com persoanl

# optional
# @browser com.google.Chrome
# @fallback tars
```

Supported browser bundle IDs: Helium, Chrome, Chromium, Brave, Edge and Vivaldi. Profile names must already exist; the router never creates profiles from typos. Local files use the browser's last-used profile.

## Check

```sh
APP="/Applications/URL to Profile Router.app/Contents/MacOS/Router"
"$APP" --check
"$APP" --list-profiles
"$APP" --dry-run https://github.com/foo
```

Core routing tests run anywhere Swift is available:

```sh
swiftc Core.swift CoreTests.swift -o /tmp/router-tests && /tmp/router-tests
```
