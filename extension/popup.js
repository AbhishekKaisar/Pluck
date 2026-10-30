import { DEFAULTS, getSettings, findApp } from "./common.js";

const $ = (id) => document.getElementById(id);

async function refreshStatus() {
  const settings = await getSettings();
  const port = await findApp(settings);
  const dot = $("dot");
  const status = $("status");
  if (port) {
    dot.className = "dot on";
    status.textContent = settings.token ? `Running on ${port}` : "Running, token missing";
    if (port !== Number($("port").value)) $("port").value = port;
  } else {
    dot.className = "dot off";
    status.textContent = "Pluck is not running";
  }
  dot.title = status.textContent;
}

async function load() {
  const s = await getSettings();
  $("enabled").checked = s.enabled;
  $("token").value = s.token;
  $("port").value = s.port;
  $("minSizeMB").value = s.minSizeMB;
  $("catchAll").checked = s.catchAll;
  $("types").value = s.types;
  refreshStatus();
}

async function save() {
  const port = Math.min(65535, Math.max(1024, parseInt($("port").value, 10) || DEFAULTS.port));
  await chrome.storage.local.set({
    enabled: $("enabled").checked,
    token: $("token").value.trim(),
    port,
    minSizeMB: Math.max(0, parseFloat($("minSizeMB").value) || 0),
    catchAll: $("catchAll").checked,
    types: $("types").value.trim(),
  });
  chrome.action.setBadgeText({ text: "" });
  $("saved").textContent = "Saved";
  setTimeout(() => ($("saved").textContent = ""), 1500);
  refreshStatus();
}

$("save").addEventListener("click", save);
$("enabled").addEventListener("change", save);
$("catchAll").addEventListener("change", save);
$("reset").addEventListener("click", () => {
  $("types").value = DEFAULTS.types;
});

load();
