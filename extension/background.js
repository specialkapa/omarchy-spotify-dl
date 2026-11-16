// Sends Spotify and YouTube links to the Omarchy Spotify Downloader plugin through the
// native messaging host registered as com.specialkapa.spotify_dl
// (bin/native-host in the plugin folder).

const HOST = "com.specialkapa.spotify_dl";
const MENU_LINK = "spotify-dl-link";
const MENU_PAGE = "spotify-dl-page";
const LINK_PATTERNS = ["https://open.spotify.com/*", "https://*.youtube.com/*", "https://youtu.be/*"];

// Same rules as the plugin (Logic.js / bin/spotify-dl): Spotify track, album
// or playlist; a YouTube video (even with &list=, which is usually an endless
// mix), a YouTube playlist, or a YouTube Music album page.
const LINK_RES = [
  /^https:\/\/open\.spotify\.com\/(?:intl-[a-z]{2}(?:-[a-z]{2})?\/)?(?:embed\/)?(track|album|playlist)\/[A-Za-z0-9]{22}(?:[/?#]\S*)?$/i,
  /^https:\/\/(?:(?:www|m|music)\.)?(?:youtube\.com\/(?:watch\?(?:[^#\s]*&)?v=|shorts\/|live\/)|youtu\.be\/)[A-Za-z0-9_-]{11}(?:[?&#/]\S*)?$/i,
  /^https:\/\/(?:(?:www|m|music)\.)?youtube\.com\/playlist\?(?:[^#\s]*&)?list=(?!RD)[A-Za-z0-9_-]{10,64}(?:[&#]\S*)?$/i,
  /^https:\/\/music\.youtube\.com\/browse\/MPREb_[A-Za-z0-9_-]{6,40}(?:[?#]\S*)?$/i,
];

function isSupportedLink(url) {
  return typeof url === "string" && url.length < 2000 && LINK_RES.some((re) => re.test(url));
}

function setupMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU_LINK,
      title: "Download with Spotify Downloader",
      contexts: ["link"],
      targetUrlPatterns: LINK_PATTERNS,
    });
    chrome.contextMenus.create({
      id: MENU_PAGE,
      title: "Download this page with Spotify Downloader",
      contexts: ["page"],
      documentUrlPatterns: LINK_PATTERNS,
    });
  });
}

chrome.runtime.onInstalled.addListener(setupMenus);
chrome.runtime.onStartup.addListener(setupMenus);

const BADGES = {
  sending: { text: "…", color: "#666666" },
  started: { text: "✓", color: "#1f9d55" },
  busy: { text: "⏳", color: "#c27c0e" },
  invalid: { text: "?", color: "#c27c0e" },
  error: { text: "!", color: "#d0342c" },
};

let clearTimer = null;

function badge(tabId, kind, title) {
  const b = BADGES[kind];
  const target = tabId !== undefined ? { tabId } : {};
  chrome.action.setBadgeText({ ...target, text: b.text });
  chrome.action.setBadgeBackgroundColor({ ...target, color: b.color });
  chrome.action.setTitle({ ...target, title: title || "Download with Spotify Downloader" });
  clearTimeout(clearTimer);
  if (kind !== "sending") {
    clearTimer = setTimeout(() => {
      chrome.action.setBadgeText({ ...target, text: "" });
      chrome.action.setTitle({ ...target, title: "Download with Spotify Downloader" });
    }, kind === "error" ? 8000 : 4000);
  }
}

function send(url, tabId) {
  if (!isSupportedLink(url)) {
    badge(tabId, "invalid", "Open a Spotify or YouTube track, album or playlist first");
    return;
  }
  badge(tabId, "sending", "Sending to Spotify Downloader…");
  chrome.runtime.sendNativeMessage(HOST, { url }, (reply) => {
    if (chrome.runtime.lastError) {
      badge(tabId, "error", "Spotify Downloader host not reachable: " + chrome.runtime.lastError.message +
        "\nRun bin/install-browser-host in the plugin folder.");
      return;
    }
    const status = reply && typeof reply.status === "string" ? reply.status : "error";
    const message = reply && typeof reply.message === "string" ? reply.message.slice(0, 300) : "";
    if (status === "started") badge(tabId, "started", "Download started");
    else if (status === "busy") badge(tabId, "busy", "Spotify Downloader is busy with another download");
    else if (status === "invalid") badge(tabId, "invalid", message || "Not a Spotify or YouTube track, album or playlist link");
    else badge(tabId, "error", "Spotify Downloader: " + (message || "failed"));
  });
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const tabId = tab && tab.id >= 0 ? tab.id : undefined;
  if (info.menuItemId === MENU_LINK) send(info.linkUrl, tabId);
  else if (info.menuItemId === MENU_PAGE) send(info.pageUrl, tabId);
});

chrome.action.onClicked.addListener((tab) => send(tab && tab.url, tab && tab.id));
