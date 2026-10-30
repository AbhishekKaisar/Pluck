# MacDownloader

A small, native download manager for macOS in the spirit of IDM. It catches downloads from Chrome and Edge and fetches each file over several connections at once, which is usually much faster than the browser's single stream, especially on long, lossy routes.

No Electron, no third-party dependencies: Swift, SwiftUI, AppKit, `URLSession` and `Network.framework`, plus a plain Manifest V3 extension.

## What it does

- **Segmented downloads.** A `Range: bytes=0-0` probe finds the size, range support and filename (from `Content-Disposition`, else the final URL after redirects). The file is split into N segments (default 16, 1 to 32), each on its own connection, written into one preallocated `.part` file at the right offsets.
- **Dynamic splitting.** When a segment finishes, the largest remaining one is cut in half and handed to the free connection, so every connection stays busy to the end. A watchdog replaces stalled connections and, near the end, connections that have slowed to a crawl.
- **Fallback.** Servers without range support, or with an unknown size, get a single stream.
- **Pause, resume, cancel, retry.** Per-segment progress is saved in `<name>.part.json` beside the `.part` file, so resume survives quitting the app or a crash. Segment errors retry with backoff (1, 2, 4, 8, 16, 30 s). On completion the `.part` file is renamed; existing files are never overwritten (`name (1).ext`).
- **Logged-in downloads.** Cookies, referrer and user agent from the browser are sent on every request.
- **Queue and limits.** Up to 3 downloads at once by default, the rest wait in a queue. Optional global speed limit.
- **Live speed and ETA** per item over a 4 second sliding window, total speed in the menu bar.
- **Persistent list** in `~/Library/Application Support/MacDownloader/downloads.json`.

## Build

Needs the Swift command line tools (Swift 6). Xcode is not needed.

```sh
cd ~/Documents/MacDownloader
./build.sh          # release build, assembles and ad-hoc signs build/MacDownloader.app, plus build/mdl
./test.sh           # unit tests (swift-testing)
open build/MacDownloader.app
```

To install, drag `build/MacDownloader.app` into `/Applications` (or `cp -R build/MacDownloader.app /Applications/`). Because it is ad-hoc signed, the first launch from Finder may need right-click, Open.

`build.sh` passes `--build-system native` because the default SwiftPM build system fails on this machine without Xcode. `test.sh` adds the framework paths that swift-testing needs with the command line tools only.

## Install the browser extension (Chrome or Edge)

1. Open `chrome://extensions` (Chrome) or `edge://extensions` (Edge).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and choose `~/Documents/MacDownloader/extension`.
4. Pin the extension, click its icon and paste the token: in MacDownloader, open **Settings** (the gear in the toolbar) and click **Copy** next to the token. Click **Save**.
5. The dot in the popup turns green when the app is reachable.

From then on, a download that matches the file-type list and is at least the minimum size (1 MB by default) is handed to MacDownloader and removed from the browser's download list. If the app is not running, the token is wrong or the hand-over fails for any reason, the browser download carries on untouched, so nothing is lost. `blob:` and `data:` downloads and incognito windows are always left to the browser. Right-click a link and choose **Download with MacDownloader** to send any link.

Safari is not supported: a Safari extension has to be built and signed with Xcode.

## Other ways in

- Paste one or more links into the field at the top of the window.
- URL scheme: `open "macdownloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip"` (optional `filename` and `referrer`).
- Local API on `127.0.0.1:6801` (the next free port up to 6820 if taken; the chosen port is in `server.json`):
  - `GET /ping`: no token, returns the app name and version.
  - `POST /add` with `{"url", "filename"?, "referrer"?, "cookies"?, "userAgent"?, "fileSize"?}` and header `X-MacDownloader-Token: <token>` (or `Authorization: Bearer <token>`).
  - `GET /list`, `POST /control` with `{"id", "action": "pause" | "resume" | "cancel"}`, both with the token.
  - Requests without the token get 401. Requests carrying a web page `Origin` get 403. Only loopback connections are accepted.
- Command line: `build/mdl [-c connections] [-o directory] [-n filename] [-l KiB/s] URL`. Ctrl-C pauses and saves state; the same command again resumes.

## Files

```
Package.swift
build.sh, test.sh
Resources/Info.plist, AppIcon.icns
Sources/DownloaderCore/   engine, segment maths, file naming, manager, local server
Sources/MacDownloader/    SwiftUI app: window, settings sheet, menu bar extra
Sources/mdl/              command line front end to the engine
Tests/DownloaderCoreTests/
extension/                Manifest V3 extension for Chrome and Edge
scripts/make-icons.swift  draws the icons
```

## Known limits

- Safari is out of scope (needs Xcode).
- Each connection uses its own `URLSession`, so it gets its own TCP connection; one shared session would multiplex everything over one HTTP/2 connection and lose the speed-up. Some servers cap or block clients that open many connections; lower the connection count for those.
- Cookies are sent as a plain `Cookie` header and dropped when a redirect leads to an unrelated host, which can break the rare download that needs the same cookies on a different domain.
- With a speed limit on, each connection fetches small ranges paced by a shared token bucket, so the network itself stays under the limit (measured 1.03 MB/s on the wire at a 1024 KiB/s limit). Servers without range support are not limited.
- Downloads that need a POST body, or a page-bound token that the browser holds outside cookies, cannot be repeated by the app; turn the extension off for those sites or use the browser.
- No browser integration for Firefox or Safari, no video grabbing from pages, no scheduler.
