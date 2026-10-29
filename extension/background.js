// MacDownloader service worker.
// Catches browser downloads and hands them to the app on 127.0.0.1. The rule that matters most:
// the browser download is cancelled only after the app has accepted it, so nothing is ever lost.

import {
  getSettings,
  findApp,
  sendToApp,
  cookieHeader,
  matchesType,
  fileNameFromPath,
  fileNameFromURL,
} from "./common.js";

const MENU_ID = "macdownloader-link";
// URLs we hand back to the browser ourselves (context menu fallback); never catch them again.
const bypass = new Set();

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_ID,
      title: "Download with MacDownloader",
      contexts: ["link", "video", "audio", "image"],
    });
  });
});

function badge(text, colour) {
  chrome.action.setBadgeText({ text });
  if (colour) chrome.action.setBadgeBackgroundColor({ color: colour });
}

function sizeOf(item) {
  if (item.fileSize > 0) return item.fileSize;
  if (item.totalBytes > 0) return item.totalBytes;
  return -1;
}

/** Returns true when the app took the download and the browser copy was cancelled. */
async function tryCatch(item) {
  const settings = await getSettings();
  if (!settings.enabled) return false;
  const url = item.finalUrl || item.url;
  if (!/^https?:/i.test(url)) return false; // skips blob:, data:, file: and the rest
  if (bypass.has(url) || bypass.has(item.url)) {
    bypass.delete(url);
    bypass.delete(item.url);
    return false;
  }
  if (item.incognito) return false; // keep private windows private
  if (item.state && item.state !== "in_progress") return false;

  const size = sizeOf(item);
  const minBytes = Math.max(0, Number(settings.minSizeMB) || 0) * 1024 * 1024;
  if (size >= 0 && size < minBytes) return false;

  const name = fileNameFromPath(item.filename) || fileNameFromURL(url);
  if (!matchesType(name, item.mime, settings)) return false;

  if (!settings.token) {
    badge("!", "#c0392b");
    return false;
  }
  const port = await findApp(settings);
  if (!port) return false;

  const result = await sendToApp(port, settings.token, {
    url,
    filename: name || undefined,
    referrer: item.referrer || undefined,
    cookies: (await cookieHeader(url)) || undefined,
    userAgent: navigator.userAgent,
    fileSize: size > 0 ? size : undefined,
  });
  if (!result.ok) {
    if (result.status === 401) badge("!", "#c0392b");
    return false;
  }
  badge("", null);
  try {
    await chrome.downloads.cancel(item.id);
  } catch {}
  try {
    await chrome.downloads.erase({ id: item.id });
  } catch {}
  return true;
}

// onDeterminingFilename fires once the response headers are in, so size, MIME and the server's
// filename are known. Returning true keeps Chrome waiting for suggest() while we ask the app.
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  let answered = false;
  const answer = () => {
    if (answered) return;
    answered = true;
    try {
      suggest();
    } catch {}
  };
  // Safety net: never hold a download for long, even if something below hangs.
  const timer = setTimeout(answer, 5000);
  tryCatch(item)
    .catch(() => false)
    .finally(() => {
      clearTimeout(timer);
      answer();
    });
  return true;
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  if (!url || !/^https?:/i.test(url)) return;
  const settings = await getSettings();
  const port = settings.token ? await findApp(settings) : null;
  let ok = false;
  if (port) {
    const result = await sendToApp(port, settings.token, {
      url,
      referrer: info.pageUrl || (tab && tab.url) || undefined,
      cookies: (await cookieHeader(url)) || undefined,
      userAgent: navigator.userAgent,
    });
    ok = result.ok;
  }
  if (!ok) {
    // App not reachable: let the browser download it as usual.
    bypass.add(url);
    chrome.downloads.download({ url });
  }
});
