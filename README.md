# Spotify Downloader (Omarchy shell plugin)

Paste a **Spotify or YouTube** track, album or playlist link and get tagged
MP3s.

## Install

```bash
omarchy pkg add yt-dlp ffmpeg mpd rmpc mpd-mpris wl-clipboard libnotify jq
omarchy plugin add https://github.com/specialkapa/omarchy-spotify-dl.git --enable --yes
~/.config/omarchy/plugins/specialkapa.spotify-dl/bin/install-browser-host   # optional: Brave extension
```

Then add `"specialkapa.spotify-dl"` to the tray (or a bar section) in `~/.config/omarchy/shell.json`.

- **Tray icon**: click to open the panel (it pre-fills a Spotify link from the
  clipboard), press Enter or *Download*. Right-click downloads the link on the
  clipboard straight away.
- **Files**: `~/Music/Spotify/artist - title (feat. other artists).mp3`, all
  lowercase. Albums and playlists get their own lowercase subfolder. Existing
  files are skipped, so re-running a playlist only fetches new tracks.
- **Tags** (original case, for filtering in your player):
  | tag | value |
  |---|---|
  | `artist`, `album_artist` | primary artist only (clean artist filter) |
  | `title` | `Title (feat. Other Artists)` |
  | `artists` | full list, `A; B; C` |
  | `genre` | from Deezer's public catalogue, e.g. `Pop`, `Rap/Hip Hop`, `Dance` (see below) |
  | `grouping` | playlist or album name |
  | `source` | `album`, `playlist` or `track`: what kind of link it came from |
  | `album`, `track` | albums only |
  | `comment` | the YouTube source URL |
  | cover | embedded front cover: Spotify's own art, else the Deezer album cover, else the YouTube thumbnail |

## Library tab

Switch the panel to **Library** to browse and play what you've downloaded:

- Browse by **Genres**, **Artists** (featured appearances count, so an artist
  shows every track they're on), **Albums** or **Playlists**, each with track
  counts. Album downloads appear only under Albums, playlist downloads only
  under Playlists.
  Click a value to add it as a filter; filters combine (e.g. *Pop* + an
  artist) and show as chips you click to remove.
- **Tracks** lists the matches; type to search title, artists, album, genre
  and playlist together. Click a track to play the list from there, or use
  **Play** / **Shuffle** for the whole filtered list. Enter in the search box
  plays the list.
- Playback runs in **MPD** (the Music Player Daemon, a user service), so it
  keeps playing when the panel closes, the shell reloads or the player
  window is closed. With `mpd-mpris` the bar's media widget and media keys
  control it; the panel shows now-playing with prev / pause / next / open
  player / stop.
- **Open player** (⧉, in the now-playing row and next to Play / Shuffle)
  opens **rmpc**, a terminal MPD client with album art, queue, and Artists,
  Album Artists, Genres and Albums tabs, floating and centered via a
  Hyprland rule in `~/.config/hypr/hyprland.lua`. Closing it (`q`) leaves
  the music playing.
- Setup: `mpd mpc rmpc mpd-mpris` packages; `~/.config/mpd/mpd.conf` with
  `music_directory "~/Music/Spotify"` (must contain the download folder),
  `auto_update "yes"`; `systemctl --user enable --now mpd mpd-mpris`.
  rmpc's config (with the Genres tab) is `~/.config/rmpc/config.ron`.
- Tags are read with a small built-in ID3 reader and cached in
  `~/.cache/specialkapa.spotify-dl/library.json`; the library rescans after
  each download, or with the refresh button.

## Genres

Spotify has no public genre data, so genres come from Deezer (no account),
trying in order:

1. the genre of the Deezer album the track is on
2. for album downloads, the album's genre, applied to every track
3. the artist's most common genre across their Deezer albums (then the
   featured artists')
4. the **Fallback genre** setting (default `Unknown`; empty writes none)

Add genres to files that have none (only the genre tag changes, the audio is
copied untouched):

```bash
bin/spotify-dl --fill-genres ~/Music/Spotify [--fallback-genre Unknown]
```

## YouTube

Accepted: videos (`youtube.com/watch`, `youtu.be`, `shorts/`,
`music.youtube.com/watch`), playlists (`youtube.com/playlist?list=…`) and
YouTube Music albums (`music.youtube.com/browse/MPREb_…` or `OLAK5uy_…`
playlists, which are treated as albums with track numbers).

- A watch link with `&list=` downloads just that video; those lists are
  usually endless auto-generated mixes. Mix playlists (`list=RD…`) are refused.
- Artist and title come from yt-dlp's metadata when YouTube provides it,
  otherwise from the title: `Artist - Song (Official Video) ft. X` becomes
  `artist - song (feat. x)`; without a dash the channel is the artist
  (` - Topic` / `VEVO` removed).
- Same naming, Library, genre lookup and tags as Spotify, plus
  `origin=youtube` (Spotify downloads get `origin=spotify`).
- Up to 500 videos of a playlist are downloaded.

## Covers

New downloads get the album cover embedded. Add covers to existing files
(audio and tags untouched):

```bash
bin/spotify-dl --fill-covers ~/Music/Spotify
```

## How it works

Spotify audio is DRM-protected, so `bin/spotify-dl` reads the public track
list from Spotify's embed page, asks yt-dlp for the top 5 YouTube results
per track, picks the one whose duration is closest (penalising live / cover /
remix uploads), extracts MP3 (best VBR) and writes tags with ffmpeg.
Network access only happens when you start a download; there is no
background polling.

Limits: Spotify's embed page lists at most 100 tracks of a playlist;
`spotify.link` short links aren't supported (open them and copy the full
`open.spotify.com` URL); genre is best-effort and left empty when Deezer has
no confident match.

## Brave extension

`extension/` sends Spotify and YouTube links from the browser straight to this plugin:
right-click a Spotify or YouTube link → *Download with Spotify Downloader*,
or click the toolbar button on a Spotify or YouTube track / album / playlist page.
The button's badge shows ✓ started, ⏳ busy, ? not a Spotify link, ! error
(hover it for details).

Setup (once):

1. `bin/install-browser-host` registers the native messaging host for Brave
   (`bin/install-browser-host brave-beta chromium …` for others;
   `--remove` to undo).
2. In `brave://extensions`, turn on *Developer mode*, click *Load unpacked*
   and pick this plugin's `extension/` folder.

The extension ID is pinned by the `key` in its manifest
(`hoiinglkkfdpckajopjghjcnhfociepc`) and only that ID may start
`bin/native-host`, which accepts only strict Spotify track/album/playlist
links and passes them to `omarchy-shell specialkapa.spotify-dl download`.

## Command line / IPC

```bash
bin/spotify-dl 'https://open.spotify.com/playlist/…'           # human output
bin/spotify-dl --json --out ~/Music/Other '<link>'             # JSON lines
omarchy-shell specialkapa.spotify-dl download '<link>'
omarchy-shell specialkapa.spotify-dl downloadClipboard
omarchy-shell specialkapa.spotify-dl status | cancel | open
omarchy-shell specialkapa.spotify-dl library                    # open on the Library tab
omarchy-shell specialkapa.spotify-dl playPause | next | previous | stop | showPlayer (open rmpc) | hidePlayer
bin/library scan | play [--shuffle] [--start N] PATH... | ctl toggle|next|prev|stop|show|hide | status
```

## Settings

Open the panel's **Settings** tab (or right-click the Audio Visualizer on the
bar). It edits this widget's settings and the Audio Visualizer's, saved with
`omarchy bar set` and applied live:

- Downloads: `outputDir` (default `~/Music/Spotify`), `fallbackGenre`
  (default `Unknown`), `notify` (default `true`).
- Audio Visualizer: style (bars / mirrored / waves / mirrored waves), number
  of bars, bar width, spacing, height, loudness gradient, custom colors,
  hide when idle.

The same keys can be set by hand in each widget's entry in
`~/.config/omarchy/shell.json`.

## Tests

```bash
python3 -I tests/test_spotify_dl.py
python3 -I tests/test_library.py
python3 -I tests/test_native_host.py
python3 -I tests/test_mpd.py
node tests/logic.test.cjs
```

Requires `python3`, `yt-dlp`, `ffmpeg`, `mpd` + `rmpc` (+ `mpd-mpris` for bar control), `wl-clipboard`, `libnotify`.
