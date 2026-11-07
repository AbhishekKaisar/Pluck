# Changelog

## Unreleased

- New setting, "Ask where to save each download" (off by default). When it is on, each browser download opens the Add sheet with its name, size and the default folder, and starts only when you click Download. Downloads that arrive meanwhile wait their turn, and the sheet comes forward even when the window is closed. The Folder row in Settings is now called "Default folder". Reload the extension for this to apply to its downloads.
- The browser extension now starts Pluck when it is closed, so a download is caught even when the app is not running. Pluck registers a small start-up script with Chrome, Edge, Brave, Vivaldi, Arc and Chromium each time it opens, so open it once after updating.
- The extension has a fixed ID now. If you already use it, remove it, load the new folder and paste the token again: the browser treats it as a new extension and forgets the saved token.

## 1.0.0 (2026-10-30)

First public release.

- Downloads each file over up to 32 connections at once (16 by default), with dynamic splitting so every connection stays busy to the end, and a watchdog that replaces stalled connections.
- Chrome and Edge extension that hands matching downloads to Pluck, with cookies, referrer and user agent, so logged-in downloads work. If Pluck is not running, the browser download carries on as normal.
- Pause and resume that survive quitting the app, a crash or a restart.
- Main window with sort, filter, search, multi-select actions, a detail panel and a live map of every connection.
- Add sheet that reads links from the clipboard, checks a link's name, size and resume support, and takes many links at once.
- Queue, global speed limit, menu bar speed, "File missing" detection, link import and export.
- Local API on 127.0.0.1 and the `mdl` command line tool.
- Universal app for Apple silicon and Intel Macs, macOS 14 or later.
- Renamed from MacDownloader during development: settings, token and download list move across from `~/Library/Application Support/MacDownloader` on first launch, and the old `macdownloader://` links still work.
