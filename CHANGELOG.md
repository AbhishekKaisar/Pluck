# Changelog

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
