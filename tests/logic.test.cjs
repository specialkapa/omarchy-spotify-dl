// Run: node tests/logic.test.cjs
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Logic.js"), "utf8").replace(/^\.pragma library\s*/, "")
const module_ = { exports: {} }
new Function("module", src)(module_)
const L = module_.exports

// Links
assert.ok(L.isSpotifyLink("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc"))
assert.ok(L.isSpotifyLink(" spotify:playlist:37i9dQZF1DXcBWIGoYBM5M "))
assert.ok(!L.isSpotifyLink("https://open.spotify.com/artist/0gxyHStUsqpMadRV0Di1Qt"))
assert.ok(!L.isSpotifyLink("https://evil.example/track/4uLU6hMCjMI75M1A2tKUQC"))
assert.ok(!L.isSpotifyLink("spotify:track:4uLU6hMCjMI75M1A2tKUQC; rm -rf ~"))
assert.ok(L.isSpotifyLink("https://youtu.be/dQw4w9WgXcQ?si=x"))
assert.ok(L.isSpotifyLink("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ"))
assert.ok(L.isSpotifyLink("https://www.youtube.com/playlist?list=PLSdoVPM5WnndSQEXRz704yQkKwx76GvPV"))
assert.ok(L.isSpotifyLink("https://music.youtube.com/browse/MPREb_7ltM34kr0mH"))
assert.ok(!L.isSpotifyLink("https://www.youtube.com/playlist?list=RDdQw4w9WgXcQ"))
assert.ok(!L.isSpotifyLink("https://www.youtube.com.evil.example/watch?v=dQw4w9WgXcQ"))
assert.ok(!L.isSpotifyLink("https://www.youtube.com/@channel"))

// Events are validated and bounded
assert.strictEqual(L.parseEvent("not json"), null)
assert.strictEqual(L.parseEvent('{"event":"exec"}'), null)
const ev = L.parseEvent(JSON.stringify({ event: "track", status: "pwned", index: -4, total: "1e9", name: "x".repeat(999) + "\n" }))
assert.strictEqual(ev.status, "")
assert.strictEqual(ev.index, 0)
assert.strictEqual(ev.total, 0)
assert.strictEqual(ev.name.length, 200)
assert.ok(!/\n/.test(ev.name))

// Markup-shaped names cannot reach the notification daemon as markup
const tracker = '<img src="https://example.invalid/tracker"> & <b>x</b>'
const escaped = L.escapeMarkup(tracker)
assert.ok(!/[<>]/.test(escaped))
assert.strictEqual(escaped, "&lt;img src=&quot;https://example.invalid/tracker&quot;&gt; &amp; &lt;b&gt;x&lt;/b&gt;")

// Paths
assert.strictEqual(L.expandHome("~/Music/Spotify", "/home/u"), "/home/u/Music/Spotify")
assert.strictEqual(L.expandHome("", "/home/u"), "/home/u/Music/Spotify")
assert.strictEqual(L.expandHome("/srv/music", "/home/u"), "/srv/music")

// Recent list
let r = []
for (let i = 0; i < 10; i++) r = L.pushRecent(r, { name: "t" + i }, 6)
assert.strictEqual(r.length, 6)
assert.strictEqual(r[0].name, "t9")

// Library
const lib = L.parseLibrary(JSON.stringify({ tracks: [
  { path: "/m/a.mp3", title: "BbY WOW (feat. Judeline)", artist: "KAROL G", artists: ["KAROL G", "Judeline"], genre: "Latin Music", grouping: "Top Hits" },
  { path: "/m/b.mp3", title: "Money", artist: "Pink Floyd", artists: ["Pink Floyd"], genre: "Rock", grouping: "The Dark Side of the Moon" },
  { path: "/m/c.mp3", title: "Time", artist: "Pink Floyd", artists: ["Pink Floyd"], genre: "rock", grouping: "The Dark Side of the Moon" },
  { path: "/m/d.mp3", title: "Solo", artist: "Judeline", artists: ["Judeline"], genre: "Pop", grouping: "Top Hits" },
  { path: "/etc/passwd", title: "nope" },
  "garbage"
] }))
assert.strictEqual(lib.length, 4)
assert.deepStrictEqual(L.parseLibrary("{bad"), [])

const genres = L.facet(lib, "genre")
assert.deepStrictEqual(genres[0], { value: "Rock", count: 2 })            // case-insensitive, by count
const artists = L.facet(lib, "artist")
assert.deepStrictEqual(artists.find(a => a.value === "Judeline"), { value: "Judeline", count: 2 }) // features count
assert.deepStrictEqual(L.facet(lib, "playlist").map(p => p.value), ["The Dark Side of the Moon", "Top Hits"])

assert.deepStrictEqual(L.filterTracks(lib, [{ kind: "artist", value: "judeline" }], "").map(t => t.path), ["/m/a.mp3", "/m/d.mp3"])
assert.deepStrictEqual(L.filterTracks(lib, [{ kind: "genre", value: "Rock" }], "tim").map(t => t.path), ["/m/c.mp3"])
assert.deepStrictEqual(L.filterTracks(lib, [{ kind: "playlist", value: "Top Hits" }, { kind: "genre", value: "Pop" }], "").map(t => t.path), ["/m/d.mp3"])
assert.strictEqual(L.filterTracks(lib, [], "pink money").length, 1)

let filters = L.setFilter([], "genre", "Rock")
filters = L.setFilter(filters, "genre", "Pop")
filters = L.setFilter(filters, "artist", "Judeline")
assert.deepStrictEqual(filters, [{ kind: "genre", value: "Pop" }, { kind: "artist", value: "Judeline" }])
assert.deepStrictEqual(L.removeFilter(filters, "genre"), [{ kind: "artist", value: "Judeline" }])
assert.strictEqual(L.filterFacet(artists, "floy").length, 1)

// Albums vs playlists
const mixed = L.parseLibrary(JSON.stringify({ tracks: [
  { path: "/m/1.mp3", title: "Efetzis", artist: "Eisvoleas", artists: ["Eisvoleas"], album: "I Viomihania ton ilithion", grouping: "I Viomihania ton ilithion", source: "album" },
  { path: "/m/2.mp3", title: "Loser", artist: "Tame Impala", artists: ["Tame Impala"], album: "", grouping: "Today's Top Hits", source: "playlist" },
  { path: "/m/3.mp3", title: "Old", artist: "X", artists: ["X"], album: "", grouping: "Road Trip" }
] }))
assert.deepStrictEqual(L.facet(mixed, "album").map(a => a.value), ["I Viomihania ton ilithion"])
assert.deepStrictEqual(L.facet(mixed, "playlist").map(a => a.value), ["Road Trip", "Today's Top Hits"])
assert.deepStrictEqual(L.filterTracks(mixed, [{ kind: "album", value: "i viomihania ton ilithion" }], "").map(t => t.path), ["/m/1.mp3"])
assert.deepStrictEqual(L.filterTracks(mixed, [{ kind: "playlist", value: "I Viomihania ton ilithion" }], "").length, 0)

// Widget settings from shell.json
const shellJson = JSON.stringify({ bar: { layout: { right: [{ id: "omarchy.clock" }, { id: "specialkapa.visualizer", style: "waves", bars: "12", gradient: false, bogus: 1 }] } } })
const defaults = { style: "bars", bars: 10, gradient: true, colors: "" }
assert.deepStrictEqual(L.widgetSettings(shellJson, "specialkapa.visualizer", defaults), { style: "waves", bars: 12, gradient: false, colors: "" })
assert.deepStrictEqual(L.widgetSettings("{bad", "x", defaults), defaults)
assert.deepStrictEqual(L.widgetSettings(shellJson, "missing", defaults), defaults)

console.log("logic tests: OK")
