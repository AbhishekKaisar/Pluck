// Shared by the service worker and the popup.

export const DEFAULTS = {
  enabled: true,
  token: "",
  port: 6801,
  minSizeMB: 1,
  catchAll: false,
  types:
    "zip,rar,7z,tar,gz,tgz,bz2,xz,zst,dmg,pkg,iso,img,exe,msi,apk,deb,rpm,appimage," +
    "mp4,mkv,avi,mov,webm,m4v,flv,wmv,ts,mp3,m4a,flac,wav,aac,ogg,opus," +
    "pdf,doc,docx,xls,xlsx,ppt,pptx,odt,ods,epub,psd,ai,bin,torrent",
};

export const PORT_RANGE = [6801, 6820];

export async function getSettings() {
  const stored = await chrome.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

function base(port) {
  return `http://127.0.0.1:${port}`;
}

/** True when the Pluck app answers on this port ("MacDownloader" is its name before the rename). */
export async function ping(port, timeoutMs = 800) {
  try {
    const r = await fetch(`${base(port)}/ping`, { signal: AbortSignal.timeout(timeoutMs), cache: "no-store" });
    if (!r.ok) return false;
    const j = await r.json();
    return !!j && (j.app === "Pluck" || j.app === "MacDownloader");
  } catch {
    return false;
  }
}

/** Finds the app: the saved port first, then the fallback range. Saves a new port when it moved. */
export async function findApp(settings) {
  if (await ping(settings.port)) return settings.port;
  for (let p = PORT_RANGE[0]; p <= PORT_RANGE[1]; p++) {
    if (p === settings.port) continue;
    if (await ping(p, 300)) {
      await chrome.storage.local.set({ port: p });
      return p;
    }
  }
  return null;
}

export const HOST_NAME = "io.github.abhishekkaisar.pluck";

/** Like findApp, but starts the app through the native messaging host when it is closed.
 *  Returns null quickly when the host is not installed. Never throws. */
export async function ensureApp(settings) {
  try {
    const port = await findApp(settings);
    if (port) return port;
    try {
      await chrome.runtime.sendNativeMessage(HOST_NAME, { action: "launch" });
    } catch {
      return null; // host not installed or app deleted: the browser downloads the file itself
    }
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 200));
      const p = await findApp(settings);
      if (p) return p;
    }
  } catch {}
  return null;
}

/** Posts a download to the app. Resolves to { ok, status }. Never throws. */
export async function sendToApp(port, token, payload) {
  try {
    const r = await fetch(`${base(port)}/add`, {
      method: "POST",
      // Bearer works with every version of the app, before and after the rename.
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(3000),
    });
    let body = null;
    try {
      body = await r.json();
    } catch {}
    return { ok: r.ok && !!(body && body.ok), status: r.status };
  } catch {
    return { ok: false, status: 0 };
  }
}

/** The Cookie header value the browser would send for this URL. */
export async function cookieHeader(url, storeId) {
  try {
    const query = storeId ? { url, storeId } : { url };
    const cookies = await chrome.cookies.getAll(query);
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

export function extensionOf(name) {
  const lower = (name || "").toLowerCase();
  for (const compound of ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]) {
    if (lower.endsWith("." + compound)) return compound.split(".").pop();
  }
  const dot = lower.lastIndexOf(".");
  return dot > 0 ? lower.slice(dot + 1) : "";
}

export function typeList(types) {
  return new Set(
    String(types || "")
      .split(/[\s,]+/)
      .map((t) => t.trim().replace(/^\./, "").toLowerCase())
      .filter(Boolean),
  );
}

const CATCH_MIME = /^(video|audio)\/|^application\/(octet-stream|zip|x-zip|x-rar|x-7z|x-tar|gzip|x-gzip|x-apple-diskimage|x-msdownload|x-iso9660|pdf|vnd\.)/i;

/** Decides whether a file with this name and MIME type is on the catch list. */
export function matchesType(name, mime, settings) {
  if (settings.catchAll) return true;
  const ext = extensionOf(name);
  if (ext) return typeList(settings.types).has(ext);
  return CATCH_MIME.test(mime || "");
}

export function fileNameFromPath(path) {
  if (!path) return "";
  const parts = String(path).split(/[\\/]/);
  return parts[parts.length - 1] || "";
}

export function fileNameFromURL(url) {
  try {
    const u = new URL(url);
    const last = u.pathname.split("/").filter(Boolean).pop() || "";
    return decodeURIComponent(last);
  } catch {
    return "";
  }
}
