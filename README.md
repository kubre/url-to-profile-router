# URL to Profile Router

A small macOS menu bar app that opens web links in the browser profile selected by a domain rule. Defaults to Helium. Requires macOS 13 or later.

## Install

```sh
./install.sh
```

The installer builds the app in `build/`, installs it in `/Applications`, and preserves existing rules. Requires Xcode Command Line Tools.

Choose **Set as Default Browser** from the menu bar icon, or run:

```sh
"/Applications/URL to Profile Router.app/Contents/MacOS/Router" --set-default
```

## Rules

Edit `~/.config/url-router.conf`, or choose **Edit Rules** from the menu. Changes apply to the next link.

```text
@browser net.imput.helium
@fallback Personal
github.com Work
youtube.com Personal
```

Rules run from top to bottom; the first match wins. Domains include subdomains. Blank lines and lines starting with `#` are ignored. Profile names can contain spaces. Use a profile directory such as `Profile 2` to distinguish duplicate names.

Without a matching rule or `@fallback`, the browser chooses its profile. Local `file://` links also use the browser's default behavior.

Profile routing supports Helium, Chrome, Chromium, Brave, Edge, and Vivaldi. `--list-profiles` prints the names available in the configured browser.

Browser bundle IDs:

| Browser | Bundle ID |
| --- | --- |
| Helium | `net.imput.helium` |
| Chrome | `com.google.Chrome` |
| Chromium | `org.chromium.Chromium` |
| Brave | `com.brave.Browser` |
| Edge | `com.microsoft.edgemac` |
| Vivaldi | `com.vivaldi.Vivaldi` |

Rules can also select a different browser:

```text
@browser net.imput.helium
@fallback Personal
github.com com.google.Chrome::Work
youtube.com net.imput.helium::Personal
example.com com.brave.Browser::
```

Use `browser-bundle-id::profile` for a specific browser and profile, or `browser-bundle-id::` to let that browser choose its profile. Plain profile names use `@browser`. This also works with `@fallback`. `--list-profiles` lists profiles from all browsers referenced in the rules.

Firefox-based browsers are not supported. Their profile launch flags do not provide reliable routing to already-running profiles without additional integration.

## Check routing

```sh
APP="/Applications/URL to Profile Router.app/Contents/MacOS/Router"
"$APP" --check
"$APP" --list-profiles
"$APP" --dry-run https://github.com/foo
```

`--check` validates configured profile names and reports the current HTTP and HTTPS handlers. `--dry-run` checks a route without opening a browser.

## Test

```sh
swiftc Core.swift CoreTests.swift -o /tmp/url-router-tests
/tmp/url-router-tests
```
