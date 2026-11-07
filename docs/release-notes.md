# Pluck {{VERSION}}

Pluck is a fast, tiny download manager for the Mac. It splits each file across up to 32 connections, catches your Chrome and Edge downloads, and resumes after a restart. Free and open source, no ads, no tracking.

## Highlights

- Up to 32 connections per download (16 by default), kept busy to the end by splitting the largest remaining piece.
- Chrome and Edge extension that hands downloads to Pluck with your cookies, so logged-in downloads work. If Pluck is closed, the extension starts it in the background.
- Pause and resume that survive quitting, crashes and restarts.
- Live connection map, sort, filter, search, multi-select, queue and speed limit.
- 2.4 MB universal app for Apple silicon and Intel, 0% CPU when idle.
- On a 315 Mbps line, a 100 MB file from a distant server took 48 s with 8 connections against 493 s over a single connection.

## Install

1. Download `Pluck-{{VERSION}}.dmg`, open it and drag Pluck into Applications.
2. Pluck is not signed with a paid Apple developer certificate, so the first time you open it, right-click Pluck in Applications and choose **Open**, then **Open** again. Or try to open it once, then go to **System Settings > Privacy & Security** and click **Open Anyway**.
3. For the browser extension, unzip `Pluck-Extension-{{VERSION}}.zip` somewhere it will stay, open `chrome://extensions` or `edge://extensions`, turn on **Developer mode**, click **Load unpacked** and choose the `Pluck-Extension` folder. Paste the token from Pluck's Settings (Cmd+,) into the extension and click **Save**.

Requires macOS 14 Sonoma or later. `Pluck-{{VERSION}}.zip` holds the same app as the DMG.

If you used Pluck under its development name, MacDownloader, your settings, token and list move across on first launch.

The extension now has a fixed ID, so the browser treats it as new. If you already use it, remove it from `chrome://extensions`, load the new folder and paste the token again. Open Pluck once after updating so the browser can start it.

## Checksums (SHA-256)
