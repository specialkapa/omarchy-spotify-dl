.pragma library

// Pure helpers for SpotifyDl.qml, kept free of QML types so they can be
// tested with node (tests/logic.test.cjs).

var LINK_RES = [
  /^(?:https?:\/\/)?open\.spotify\.com\/(?:intl-[a-z]{2}(?:-[a-z]{2})?\/)?(?:embed\/)?(track|album|playlist)\/[A-Za-z0-9]{22}(?:[\/?#]\S*)?$/i,
  /^spotify:(track|album|playlist):[A-Za-z0-9]{22}$/i,
  // YouTube: one video (even with &list=, usually an endless mix), a playlist, or a YouTube Music album page.
  /^(?:https?:\/\/)?(?:(?:www|m|music)\.)?(?:youtube\.com\/(?:watch\?(?:[^#\s]*&)?v=|shorts\/|live\/)|youtu\.be\/)[A-Za-z0-9_-]{11}(?:[?&#\/]\S*)?$/i,
  /^(?:https?:\/\/)?(?:(?:www|m|music)\.)?youtube\.com\/playlist\?(?:[^#\s]*&)?list=(?!RD)[A-Za-z0-9_-]{10,64}(?:[&#]\S*)?$/i,
  /^(?:https?:\/\/)?music\.youtube\.com\/browse\/MPREb_[A-Za-z0-9_-]{6,40}(?:[?#]\S*)?$/i
]

// Spotify or YouTube link the downloader accepts (name kept for compatibility).
function isSpotifyLink(text) {
  var s = String(text || "").trim()
  if (s.length > 2000) return false
  for (var i = 0; i < LINK_RES.length; i++) if (LINK_RES[i].test(s)) return true
  return false
}

// Bound and flatten a string from the downloader's output.
function clip(value, limit) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .slice(0, limit || 300)
}

function count(value) {
  var n = Math.floor(Number(value))
  return isFinite(n) && n >= 0 && n < 100000 ? n : 0
}

// Parse one JSON line from bin/spotify-dl into a validated event, or null.
var EVENTS = ["start", "track", "finish", "cancelled", "error"]
var STATUSES = ["downloading", "done", "skipped", "failed"]

function parseEvent(line) {
  var raw
  try { raw = JSON.parse(line) } catch (e) { return null }
  if (!raw || typeof raw !== "object" || EVENTS.indexOf(raw.event) < 0) return null
  return {
    event: raw.event,
    kind: ["track", "album", "playlist"].indexOf(raw.kind) >= 0 ? raw.kind : "",
    name: clip(raw.name, 200),
    dir: clip(raw.dir, 1000),
    message: clip(raw.message, 200),
    error: clip(raw.error, 200),
    genre: clip(raw.genre, 60),
    status: STATUSES.indexOf(raw.status) >= 0 ? raw.status : "",
    index: count(raw.index),
    total: count(raw.total),
    done: count(raw.done),
    skipped: count(raw.skipped),
    failed: count(raw.failed),
    truncated: raw.truncated === true,
    limit: count(raw.limit),
    provider: raw.provider === "youtube" ? "youtube" : "spotify"
  }
}

// Notification bodies may be rendered as markup by the notification daemon.
function escapeMarkup(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}

function expandHome(path, home) {
  var p = String(path || "").trim()
  if (p === "") p = "~/Music/Spotify"
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.slice(1)
  return p
}

// Keep the newest `limit` entries of the recent-tracks list.
function pushRecent(list, entry, limit) {
  var next = list.filter(function (r) { return r.name !== entry.name })
  next.unshift(entry)
  return next.slice(0, limit || 6)
}

// ---------------------------------------------------------------- library --

function fold(s) { return String(s || "").toLocaleLowerCase() }

// Validate and bound `bin/library scan` output.
function parseLibrary(text, limit) {
  var raw
  try { raw = JSON.parse(text) } catch (e) { return [] }
  var list = raw && Array.isArray(raw.tracks) ? raw.tracks.slice(0, limit || 20000) : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var t = list[i]
    if (!t || typeof t.path !== "string" || !/\.mp3$/i.test(t.path)) continue
    var artists = Array.isArray(t.artists) ? t.artists.slice(0, 20).map(function (a) { return clip(a, 200) }).filter(function (a) { return a !== "" }) : []
    var artist = clip(t.artist, 200)
    out.push({
      path: clip(t.path, 4000),
      title: clip(t.title, 300),
      artist: artist,
      artists: artists.length ? artists : [artist],
      album: clip(t.album, 300),
      source: ["album", "playlist", "track"].indexOf(t.source) >= 0 ? t.source : "",
      genre: clip(t.genre, 60),
      grouping: clip(t.grouping, 300)
    })
  }
  return out
}

// Facet values with counts. Artists include featured appearances.
// kind: "genre" | "artist" | "album" | "playlist"
// Albums are album tags; playlists are only what was downloaded from a
// playlist link, so an album never shows up as a playlist too.
function facet(tracks, kind) {
  var counts = {}, labels = {}
  function add(v) {
    if (!v) return
    var k = fold(v)
    counts[k] = (counts[k] || 0) + 1
    if (!labels[k]) labels[k] = v
  }
  for (var i = 0; i < tracks.length; i++) {
    var t = tracks[i]
    if (kind === "genre") add(t.genre)
    else if (kind === "album") add(t.album)
    else if (kind === "playlist") add(playlistOf(t))
    else for (var j = 0; j < t.artists.length; j++) add(t.artists[j])
  }
  var out = Object.keys(counts).map(function (k) { return { value: labels[k], count: counts[k] } })
  out.sort(function (a, b) {
    if (kind === "genre" && b.count !== a.count) return b.count - a.count
    return fold(a.value) < fold(b.value) ? -1 : fold(a.value) > fold(b.value) ? 1 : 0
  })
  return out
}

function playlistOf(track) {
  return track.source === "playlist" || (track.source === "" && track.grouping !== track.album) ? track.grouping : ""
}

function matchesFilter(track, f) {
  var v = fold(f.value)
  if (f.kind === "genre") return fold(track.genre) === v
  if (f.kind === "album") return fold(track.album) === v
  if (f.kind === "playlist") return fold(playlistOf(track)) === v
  if (f.kind === "artist") return track.artists.some(function (a) { return fold(a) === v })
  return true
}

function matchesQuery(track, q) {
  if (!q) return true
  var hay = fold([track.title, track.artists.join(" "), track.album, track.genre, track.grouping].join(" "))
  return q.split(/\s+/).every(function (w) { return hay.indexOf(w) >= 0 })
}

// filters: [{kind, value}] combined with AND; query: free text.
function filterTracks(tracks, filters, query) {
  var q = fold(query).trim()
  return tracks.filter(function (t) {
    for (var i = 0; i < filters.length; i++) if (!matchesFilter(t, filters[i])) return false
    return matchesQuery(t, q)
  })
}

function filterFacet(values, query) {
  var q = fold(query).trim()
  if (!q) return values
  return values.filter(function (v) { return fold(v.value).indexOf(q) >= 0 })
}

// Add a filter, replacing an existing one of the same kind.
function setFilter(filters, kind, value) {
  return filters.filter(function (f) { return f.kind !== kind }).concat([{ kind: kind, value: value }])
}

function removeFilter(filters, kind) {
  return filters.filter(function (f) { return f.kind !== kind })
}

// --------------------------------------------------------------- settings --

// Settings of the bar widget `id` from shell.json text, over `defaults`.
function widgetSettings(shellJson, id, defaults) {
  var out = {}
  for (var k in defaults) out[k] = defaults[k]
  var raw
  try { raw = JSON.parse(shellJson) } catch (e) { return out }
  var layout = raw && raw.bar && raw.bar.layout ? raw.bar.layout : {}
  for (var section in layout) {
    var entries = Array.isArray(layout[section]) ? layout[section] : []
    for (var i = 0; i < entries.length; i++) {
      var e = entries[i]
      if (!e || e.id !== id) continue
      for (var key in defaults) {
        if (e[key] === undefined || e[key] === null) continue
        if (typeof defaults[key] === "number") { var n = Number(e[key]); if (isFinite(n)) out[key] = n }
        else if (typeof defaults[key] === "boolean") out[key] = e[key] === true
        else out[key] = clip(e[key], 300)
      }
      return out
    }
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = { isSpotifyLink: isSpotifyLink, parseEvent: parseEvent, escapeMarkup: escapeMarkup,
                     expandHome: expandHome, pushRecent: pushRecent, clip: clip,
                     parseLibrary: parseLibrary, facet: facet, filterTracks: filterTracks,
                     filterFacet: filterFacet, setFilter: setFilter, removeFilter: removeFilter,
                     widgetSettings: widgetSettings }
}
