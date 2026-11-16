import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Logic.js" as Logic

// Tray widget: paste a Spotify track/album/playlist link and download it as
// tagged MP3s. The work happens in bin/spotify-dl (yt-dlp + ffmpeg), which
// reports progress as JSON lines; this file only drives it and shows state.
// Nothing touches the network until a download is started.
Panel {
  id: root
  moduleName: "specialkapa.spotify-dl"
  ipcTarget: "specialkapa.spotify-dl"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string script: String(Qt.resolvedUrl("bin/spotify-dl")).replace(/^file:\/\//, "")
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string outputDir: Logic.expandHome(setting("outputDir", "~/Music/Spotify"), home)
  readonly property bool notifyOnFinish: setting("notify", true) !== false
  readonly property string fallbackGenre: Logic.clip(setting("fallbackGenre", "Unknown"), 60).trim()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.4)

  readonly property string glyphSpotify: ""
  readonly property string glyphDownload: "\u{F01DA}"
  readonly property string glyphCancel: "\u{F0156}"
  readonly property string glyphFolder: "\u{F0770}"
  readonly property string glyphPaste: "\u{F0192}"
  readonly property string glyphDone: "\u{F012C}"
  readonly property string glyphSkip: "\u{F0142}"
  readonly property string glyphFail: "\u{F0028}"

  // idle | reading | downloading | finished | cancelled | failed
  property string phase: "idle"
  readonly property bool busy: phase === "reading" || phase === "downloading"
  property string jobName: ""
  property string jobDir: ""
  property int index: 0
  property int total: 0
  property int doneCount: 0
  property int skippedCount: 0
  property int failedCount: 0
  property bool truncated: false
  property int truncatedLimit: 0
  property string errorText: ""
  property string currentName: ""
  property var recent: []
  property bool startWhenPasted: false

  // ---------- Library ----------
  readonly property string libraryScript: String(Qt.resolvedUrl("bin/library")).replace(/^file:\/\//, "")
  property string tab: "download"           // download | library
  property string libraryView: "genre"      // genre | artist | album | playlist | tracks
  property var libraryTracks: []
  property bool libraryLoaded: false
  property var filters: []                  // [{kind, value}]
  property string libraryQuery: ""
  property var player: ({ playing: false })
  readonly property var filteredTracks: Logic.filterTracks(libraryTracks, filters, libraryView === "tracks" ? libraryQuery : "")
  readonly property var facetValues: libraryView === "tracks" ? []
    : Logic.filterFacet(Logic.facet(Logic.filterTracks(libraryTracks, filters, ""), libraryView), libraryQuery)

  readonly property string glyphPlay: "\u{F040A}"
  readonly property string glyphPause: "\u{F03E4}"
  readonly property string glyphNext: "\u{F04AD}"
  readonly property string glyphPrev: "\u{F04AE}"
  readonly property string glyphStop: "\u{F04DB}"
  readonly property string glyphShuffle: "\u{F049D}"
  readonly property string glyphClose: "\u{F0156}"
  readonly property string glyphRefresh: "\u{F0450}"
  readonly property string glyphWindow: "\u{F03CC}"
  readonly property string glyphSettings: "\u{F0493}"

  // ---------- Settings tab (this widget + the Audio Visualizer widget) ----------
  // Values are written with `omarchy bar set`, which the bar applies live.
  readonly property string visualizerId: "specialkapa.visualizer"
  readonly property var visualizerDefaults: ({ style: "bars", bars: 10, barWidth: 4, barSpacing: 2, height: 60,
                                              gradient: true, colors: "", hideWhenIdle: true })
  readonly property var visualizer: Logic.widgetSettings(shellConfig.loaded ? shellConfig.text() : "",
                                                         visualizerId, visualizerDefaults)
  readonly property bool visualizerInstalled: shellConfig.loaded && shellConfig.text().indexOf('"' + visualizerId + '"') >= 0
  property var settingQueue: []

  FileView {
    id: shellConfig
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }

  function saveSetting(widgetId, key, value) {
    var cmd = ["omarchy-bar", "set", widgetId, key]
    if (typeof value === "string") cmd.push(value)
    else cmd = cmd.concat([JSON.stringify(value), "--json"])
    settingQueue = settingQueue.concat([cmd])
    if (!settingProc.running) runNextSetting()
  }

  function runNextSetting() {
    if (!settingQueue.length) return
    settingProc.command = settingQueue[0]
    settingQueue = settingQueue.slice(1)
    settingProc.running = true
  }

  function setTab(name) {
    tab = name
    if (name === "library") { loadLibrary(); refreshPlayer() }
    if (name === "settings") shellConfig.reload()
    Qt.callLater(function () {
      (name === "library" ? librarySearch : name === "settings" ? outputDirField : linkField).forceActiveFocus()
    })
  }

  function loadLibrary() {
    if (scanProc.running) return
    scanProc.command = [libraryScript, "scan", "--root", outputDir]
    scanProc.running = true
  }

  function chooseFacet(value) {
    filters = Logic.setFilter(filters, libraryView, value)
    libraryQuery = ""
    librarySearch.text = ""
    libraryView = "tracks"
  }

  function dropFilter(kind) { filters = Logic.removeFilter(filters, kind) }

  function playTracks(tracks, shuffle, startIndex) {
    if (!tracks.length || playProc.running) return
    var paths = tracks.slice(0, 5000).map(function (t) { return t.path })
    var cmd = [libraryScript, "play", "--root", outputDir, "--start", String(startIndex || 0)]
    if (shuffle) cmd.push("--shuffle")
    playProc.command = cmd.concat(["--"], paths)
    playProc.running = true
  }

  function playerCtl(action) {
    if (ctlProc.running) return
    ctlProc.command = [libraryScript, "ctl", action]
    ctlProc.running = true
  }

  function refreshPlayer() { if (!statusProc.running) statusProc.running = true }

  function filterLabel(kind) {
    return kind === "genre" ? strings.t("library.genres")
      : kind === "artist" ? strings.t("library.artists")
      : kind === "album" ? strings.t("library.albums")
      : kind === "playlist" ? strings.t("library.playlists") : strings.t("library.tracks")
  }

  function start(link) {
    var text = String(link || "").trim()
    if (busy) return
    if (!Logic.isSpotifyLink(text)) {
      errorText = strings.t("error.invalidLink")
      phase = "failed"
      return
    }
    errorText = ""
    jobName = ""
    jobDir = ""
    index = 0; total = 0; doneCount = 0; skippedCount = 0; failedCount = 0
    truncated = false
    currentName = ""
    recent = []
    phase = "reading"
    dlProc.command = [script, "--json", "--out", outputDir, "--fallback-genre", fallbackGenre, text]
    dlProc.running = true
  }

  function cancel() {
    if (dlProc.running) dlProc.signal(15)
  }

  function pasteAndMaybeStart(startAfter) {
    if (pasteProc.running) return
    startWhenPasted = startAfter === true
    pasteProc.running = true
  }

  function openFolder() {
    var dir = jobDir !== "" ? jobDir : outputDir
    Quickshell.execDetached(["xdg-open", dir])
  }

  function summaryText() {
    var parts = [strings.tn("summary.downloaded", doneCount).arg(Commons.I18n.formatNumber(doneCount))]
    if (skippedCount > 0) parts.push(strings.tn("summary.skipped", skippedCount).arg(Commons.I18n.formatNumber(skippedCount)))
    if (failedCount > 0) parts.push(strings.tn("summary.failed", failedCount).arg(Commons.I18n.formatNumber(failedCount)))
    return parts.join(" · ")
  }

  function notify(titleKey) {
    if (!notifyOnFinish) return
    Quickshell.execDetached(["notify-send", "-a", strings.t("title"), "-i", "folder-music",
                             strings.t(titleKey),
                             Logic.escapeMarkup(jobName + "\n" + summaryText())])
  }

  function handle(ev) {
    if (!ev) return
    if (ev.event === "start") {
      jobName = ev.name
      jobDir = ev.dir
      total = ev.total
      truncated = ev.truncated
      truncatedLimit = ev.limit
      phase = "downloading"
    } else if (ev.event === "track") {
      index = ev.index
      total = ev.total || total
      if (ev.status === "downloading") {
        currentName = ev.name
        return
      }
      if (ev.status === "done") doneCount++
      else if (ev.status === "skipped") skippedCount++
      else if (ev.status === "failed") failedCount++
      recent = Logic.pushRecent(recent, { name: ev.name, status: ev.status, detail: ev.status === "failed" ? ev.error : ev.genre }, 6)
    } else if (ev.event === "finish" || ev.event === "cancelled") {
      doneCount = ev.done; skippedCount = ev.skipped; failedCount = ev.failed
      currentName = ""
      phase = ev.event === "finish" ? "finished" : "cancelled"
      notify(ev.event === "finish" ? "notify.title" : "notify.cancelled")
      if (libraryLoaded) loadLibrary()
    } else if (ev.event === "error") {
      errorText = ev.message
      phase = "failed"
    }
  }

  onOpenedChanged: {
    if (!opened) return
    if (tab === "library") {
      setTab("library")
      return
    }
    // Pre-fill from the clipboard when it holds a Spotify link.
    if (!busy && linkField.text.trim() === "") pasteAndMaybeStart(false)
    Qt.callLater(function () { linkField.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "specialkapa.spotify-dl"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    // omarchy-shell specialkapa.spotify-dl download '<link>'
    function download(link: string): string {
      if (root.busy) return "busy"
      if (!Logic.isSpotifyLink(link)) return "not a Spotify or YouTube link"
      root.start(link)
      return "started"
    }
    function downloadClipboard(): void { root.pasteAndMaybeStart(true) }
    function cancel(): void { root.cancel() }
    function status(): string {
      return JSON.stringify({ state: root.phase, name: root.jobName, index: root.index, total: root.total,
                              done: root.doneCount, skipped: root.skippedCount, failed: root.failedCount,
                              dir: root.jobDir, error: root.errorText })
    }
    // Library: open on the Library tab, and transport controls.
    function library(): void { root.open(); root.setTab("library") }
    // Opens the Settings tab (the Audio Visualizer's right-click does this).
    function settings(): void { root.open(); root.setTab("settings") }
    function playPause(): void { root.playerCtl("toggle") }
    function next(): void { root.playerCtl("next") }
    function previous(): void { root.playerCtl("prev") }
    function stop(): void { root.playerCtl("stop") }
    function showPlayer(): void { root.playerCtl("show") }
    function hidePlayer(): void { root.playerCtl("hide") }
  }

  Process {
    id: settingProc
    onExited: root.runNextSetting()
  }

  Process {
    id: scanProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.libraryTracks = Logic.parseLibrary(text, 20000)
        root.libraryLoaded = true
      }
    }
  }

  Process {
    id: playProc
    onExited: statusDelay.restart()
  }

  Process {
    id: ctlProc
    onExited: statusDelay.restart()
  }

  Process {
    id: statusProc
    command: [root.libraryScript, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s
        try { s = JSON.parse(text) } catch (e) { s = null }
        root.player = s && s.playing === true ? {
          playing: true,
          paused: s.paused === true,
          title: Logic.clip(s.title, 300),
          artist: Logic.clip(s.artist, 200),
          pos: Math.max(0, Math.floor(Number(s.pos) || 0)),
          count: Math.max(0, Math.floor(Number(s.count) || 0))
        } : { playing: false }
      }
    }
  }

  // MPD needs a moment to start or switch tracks before it reports them.
  Timer { id: statusDelay; interval: 600; onTriggered: root.refreshPlayer() }
  // Now-playing stays current only while the Library tab is visible.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened && root.tab === "library"
    onTriggered: root.refreshPlayer()
  }

  Process {
    id: pasteProc
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = Logic.clip(text, 500).trim()
        if (!Logic.isSpotifyLink(t)) {
          if (root.startWhenPasted) { root.errorText = strings.t("error.invalidLink"); root.phase = "failed" }
          return
        }
        linkField.text = t
        if (root.startWhenPasted) root.start(t)
      }
    }
  }

  Process {
    id: dlProc
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.handle(Logic.parseEvent(line)) }
    }
    stderr: StdioCollector { id: dlErr; waitForEnd: true }
    onExited: function (code) {
      if (root.busy) {
        root.errorText = Logic.clip(dlErr.text.trim().split("\n").pop(), 200) || strings.t("error.crashed")
        root.phase = "failed"
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyphSpotify
    active: root.busy
    tooltipText: root.busy && root.total > 0
      ? strings.t("tooltip.busy").arg(root.jobName).arg(Commons.I18n.formatNumber(root.index)).arg(Commons.I18n.formatNumber(root.total))
      : strings.t("tooltip.idle")
    onPressed: function (b) {
      if (b === Qt.RightButton) root.pasteAndMaybeStart(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.tab === "library" ? librarySearch : root.tab === "settings" ? outputDirField : linkField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero ----------
      Item {
        width: parent.width
        implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

        Text {
          id: heroIcon
          textFormat: Text.PlainText
          text: root.glyphSpotify
          color: root.busy ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: heroLabels
          anchors.left: heroIcon.right
          anchors.leftMargin: Style.space(14)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: root.tab === "settings" ? strings.t("settings.title")
              : root.tab === "library" ? strings.t("library.title")
              : root.jobName !== "" ? root.jobName : strings.t("title")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.tab === "settings" ? strings.t("settings.subtitle")
              : root.tab === "library"
              ? (!root.libraryLoaded ? strings.t("library.scanning")
                 : strings.tn("library.count", root.libraryTracks.length).arg(Commons.I18n.formatNumber(root.libraryTracks.length)))
              : root.phase === "failed" ? (root.errorText !== "" ? root.errorText : strings.t("status.failed")).toUpperCase()
              : root.phase === "reading" ? strings.t("status.reading")
              : root.phase === "downloading" ? strings.t("status.progress").arg(Commons.I18n.formatNumber(Math.max(1, root.index))).arg(Commons.I18n.formatNumber(root.total))
              : root.phase === "finished" ? strings.t("status.finished") + " · " + root.summaryText().toUpperCase()
              : root.phase === "cancelled" ? strings.t("status.cancelled") + " · " + root.summaryText().toUpperCase()
              : strings.t("status.idle")
            color: root.tab !== "library" && root.phase === "failed" ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            width: parent.width
          }
        }
      }

      ButtonGroup {
        width: parent.width
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        focusable: false
        value: root.tab
        options: [
          { value: "download", label: strings.t("tab.download"), icon: root.glyphDownload },
          { value: "library", label: strings.t("tab.library"), icon: root.glyphPlay },
          { value: "settings", label: strings.t("tab.settings"), icon: root.glyphSettings }
        ]
        onChanged: function (v) { root.setTab(v) }
      }

      PanelSeparator { foreground: root.foreground }

      // ---------- Link input ----------
      Row {
        id: inputRow
        visible: root.tab === "download"
        width: parent.width
        spacing: Style.space(6)

        TextField {
          id: linkField
          width: inputRow.width - pasteButton.width - inputRow.spacing
          enabled: !root.busy
          placeholderText: strings.t("placeholder")
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onAccepted: root.start(text)
          Keys.onEscapePressed: function (event) { root.close(); event.accepted = true }
        }

        PanelActionButton {
          id: pasteButton
          anchors.verticalCenter: linkField.verticalCenter
          size: linkField.height
          iconText: root.glyphPaste
          tooltipText: strings.t("paste")
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !root.busy
          onClicked: root.pasteAndMaybeStart(false)
        }
      }

      // ---------- Progress ----------
      Column {
        width: parent.width
        spacing: Style.space(6)
        visible: root.tab === "download" && (root.phase === "downloading" || root.phase === "reading")

        Rectangle {
          width: parent.width
          height: Math.max(3, Style.space(4))
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

          Rectangle {
            height: parent.height
            radius: parent.radius
            color: Color.accent
            width: root.total > 0 ? parent.width * Math.min(1, (root.doneCount + root.skippedCount + root.failedCount) / root.total) : 0
            Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.currentName
          visible: text !== ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: strings.t("note.truncated").arg(Commons.I18n.formatNumber(root.truncatedLimit))
          visible: root.truncated
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }
      }

      // ---------- Recent tracks ----------
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.tab === "download" && root.recent.length > 0

        PanelSectionHeader {
          text: strings.t("recent")
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.recent
          delegate: Row {
            required property var modelData
            width: parent.width
            spacing: Style.space(8)

            Text {
              id: statusGlyph
              textFormat: Text.PlainText
              text: modelData.status === "done" ? root.glyphDone : modelData.status === "skipped" ? root.glyphSkip : root.glyphFail
              color: modelData.status === "failed" ? Color.urgent : modelData.status === "done" ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width - statusGlyph.width - detail.width - parent.spacing * 2
            }

            Text {
              id: detail
              textFormat: Text.PlainText
              text: modelData.detail || ""
              color: modelData.status === "failed" ? Color.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: Math.min(implicitWidth, Style.space(120))
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }
      }

      // ---------- Actions ----------
      Row {
        id: actionRow
        visible: root.tab === "download"
        width: parent.width
        spacing: Style.space(6)
        readonly property real cellWidth: (width - spacing) / 2

        Button {
          width: actionRow.cellWidth
          iconText: root.busy ? root.glyphCancel : root.glyphDownload
          text: root.busy ? strings.t("cancel") : strings.t("download")
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          enabled: root.busy || Logic.isSpotifyLink(linkField.text)
          onClicked: root.busy ? root.cancel() : root.start(linkField.text)
        }

        Button {
          width: actionRow.cellWidth
          iconText: root.glyphFolder
          text: strings.t("openFolder")
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: root.openFolder()
        }
      }

      // ---------- Library ----------
      Column {
        id: libraryPane
        visible: root.tab === "library"
        width: parent.width
        spacing: Style.space(10)

        readonly property real trackRowHeight: Style.space(42)
        readonly property real facetRowHeight: Style.space(30)
        readonly property int maxRows: 9

        // Now playing + transport (also controllable from the bar's media widget).
        Item {
          visible: root.player.playing === true
          width: parent.width
          implicitHeight: Math.max(nowText.implicitHeight, transport.implicitHeight)

          Column {
            id: nowText
            anchors.left: parent.left
            anchors.right: transport.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.player.title || ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              textFormat: Text.PlainText
              text: strings.t("library.nowPlaying")
                .arg(root.player.artist || "")
                .arg(Commons.I18n.formatNumber((root.player.pos || 0) + 1))
                .arg(Commons.I18n.formatNumber(root.player.count || 0))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Row {
            id: transport
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: root.glyphPrev; tooltipText: strings.t("library.previous")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.playerCtl("prev")
            }
            PanelActionButton {
              iconText: root.player.paused ? root.glyphPlay : root.glyphPause
              tooltipText: root.player.paused ? strings.t("library.resume") : strings.t("library.pause")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.playerCtl("toggle")
            }
            PanelActionButton {
              iconText: root.glyphNext; tooltipText: strings.t("library.next")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.playerCtl("next")
            }
            PanelActionButton {
              iconText: root.glyphWindow; tooltipText: strings.t("library.showPlayer")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: { root.playerCtl("show"); root.close() }
            }
            PanelActionButton {
              iconText: root.glyphStop; tooltipText: strings.t("library.stop")
              foreground: root.foreground; fontFamily: root.fontFamily
              onClicked: root.playerCtl("stop")
            }
          }
        }

        PanelSeparator { visible: root.player.playing === true; foreground: root.foreground }

        // Browse by
        ButtonGroup {
          width: parent.width
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.caption
          focusable: false
          value: root.libraryView
          options: [
            { value: "genre", label: strings.t("library.genres") },
            { value: "artist", label: strings.t("library.artists") },
            { value: "album", label: strings.t("library.albums") },
            { value: "playlist", label: strings.t("library.playlists") },
            { value: "tracks", label: strings.t("library.tracks") }
          ]
          onChanged: function (v) { root.libraryView = v }
        }

        TextField {
          id: librarySearch
          width: parent.width
          placeholderText: root.libraryView === "tracks" ? strings.t("library.searchTracks")
            : strings.t("library.searchFacet").arg(root.filterLabel(root.libraryView).toLocaleLowerCase())
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onTextChanged: root.libraryQuery = text
          onAccepted: {
            if (root.libraryView === "tracks") root.playTracks(root.filteredTracks, false, 0)
            else if (root.facetValues.length > 0) root.chooseFacet(root.facetValues[0].value)
          }
          Keys.onEscapePressed: function (event) {
            if (text !== "") text = ""
            else root.close()
            event.accepted = true
          }
        }

        // Active filters: click to remove.
        Flow {
          visible: root.filters.length > 0
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.filters
            delegate: Button {
              required property var modelData
              text: root.filterLabel(modelData.kind) + ": " + modelData.value
              iconText: root.glyphClose
              tooltipText: strings.t("library.removeFilter")
              fontSize: Style.font.caption
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              active: true
              onClicked: root.dropFilter(modelData.kind)
            }
          }
        }

        // Genres / artists / playlists with track counts.
        ListView {
          id: facetList
          visible: root.libraryView !== "tracks" && count > 0
          width: parent.width
          height: Math.min(count, libraryPane.maxRows) * libraryPane.facetRowHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.facetValues
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: facetList.count > libraryPane.maxRows ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff }

          delegate: CursorSurface {
            id: facetRow
            required property var modelData
            required property int index
            width: facetList.width
            height: libraryPane.facetRowHeight
            foreground: root.foreground
            hasCursor: facetMouse.containsMouse

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: facetCount.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: facetRow.modelData.value
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Text {
              id: facetCount
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: Commons.I18n.formatNumber(facetRow.modelData.count)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: facetMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.chooseFacet(facetRow.modelData.value)
            }
          }
        }

        // Matching tracks: click one to play the list from there.
        ListView {
          id: trackList
          visible: root.libraryView === "tracks" && count > 0
          width: parent.width
          height: Math.min(count, libraryPane.maxRows) * libraryPane.trackRowHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.filteredTracks
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: trackList.count > libraryPane.maxRows ? QQC.ScrollBar.AsNeeded : QQC.ScrollBar.AlwaysOff }

          delegate: CursorSurface {
            id: trackRow
            required property var modelData
            required property int index
            width: trackList.width
            height: libraryPane.trackRowHeight
            foreground: root.foreground
            hasCursor: trackMouse.containsMouse

            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: trackGenre.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                text: trackRow.modelData.title
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                textFormat: Text.PlainText
                text: trackRow.modelData.artist
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }
            Text {
              id: trackGenre
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, Style.space(110))
              textFormat: Text.PlainText
              text: trackRow.modelData.genre
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            MouseArea {
              id: trackMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.playTracks(root.filteredTracks, false, trackRow.index)
            }
          }
        }

        Text {
          visible: root.libraryLoaded && (root.libraryView === "tracks" ? trackList.count === 0 : facetList.count === 0)
          width: parent.width
          textFormat: Text.PlainText
          text: root.libraryTracks.length === 0 ? strings.t("library.empty").arg(root.outputDir) : strings.t("library.noMatches")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
        }

        Row {
          id: playRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - refreshButton.width - openPlayerButton.width - spacing * 3) / 2

          Button {
            width: playRow.cellWidth
            iconText: root.glyphPlay
            text: strings.tn("library.play", root.filteredTracks.length).arg(Commons.I18n.formatNumber(root.filteredTracks.length))
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.filteredTracks.length > 0
            onClicked: root.playTracks(root.filteredTracks, false, 0)
          }
          Button {
            width: playRow.cellWidth
            iconText: root.glyphShuffle
            text: strings.t("library.shuffle")
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            fontFamily: root.fontFamily
            bordered: true
            enabled: root.filteredTracks.length > 0
            onClicked: root.playTracks(root.filteredTracks, true, 0)
          }
          PanelActionButton {
            id: openPlayerButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphWindow
            tooltipText: strings.t("library.showPlayer")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { root.playerCtl("show"); root.close() }
          }
          PanelActionButton {
            id: refreshButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.glyphRefresh
            tooltipText: strings.t("library.rescan")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.loadLibrary()
          }
        }
      }

      // ---------- Settings ----------
      Column {
        id: settingsPane
        visible: root.tab === "settings"
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader { text: strings.t("settings.downloads"); foreground: root.foreground; fontFamily: root.fontFamily }

        SettingRow {
          label: strings.t("settings.folder")
          TextField {
            id: outputDirField
            width: parent.width
            text: root.setting("outputDir", "~/Music/Spotify")
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onEditingFinished: {
              var v = text.trim()
              if (v !== "" && v !== root.setting("outputDir", "~/Music/Spotify")) root.saveSetting(root.moduleName, "outputDir", v)
            }
            Keys.onEscapePressed: function (event) { root.close(); event.accepted = true }
          }
        }

        SettingRow {
          label: strings.t("settings.fallbackGenre")
          TextField {
            width: parent.width
            text: root.setting("fallbackGenre", "Unknown")
            placeholderText: strings.t("settings.fallbackGenreEmpty")
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onEditingFinished: if (text.trim() !== root.fallbackGenre) root.saveSetting(root.moduleName, "fallbackGenre", text.trim())
          }
        }

        SettingRow {
          label: strings.t("settings.notify")
          ToggleSwitch {
            checked: root.notifyOnFinish
            foreground: root.foreground
            onToggled: root.saveSetting(root.moduleName, "notify", !root.notifyOnFinish)
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader { text: strings.t("settings.visualizer"); foreground: root.foreground; fontFamily: root.fontFamily }

        Text {
          visible: !root.visualizerInstalled
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("settings.visualizerMissing")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Column {
          visible: root.visualizerInstalled
          width: parent.width
          spacing: Style.space(8)

          ButtonGroup {
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            focusable: false
            value: root.visualizer.style
            options: [
              { value: "bars", label: strings.t("settings.style.bars") },
              { value: "bars_mirrored", label: strings.t("settings.style.barsMirrored") },
              { value: "waves", label: strings.t("settings.style.waves") },
              { value: "waves_mirrored", label: strings.t("settings.style.wavesMirrored") }
            ]
            onChanged: function (v) { root.saveSetting(root.visualizerId, "style", v) }
          }

          SettingRow {
            label: strings.t("settings.bars")
            NumberField {
              value: root.visualizer.bars; from: 4; to: 48
              foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
              onModified: function (v) { root.saveSetting(root.visualizerId, "bars", v) }
            }
          }
          SettingRow {
            label: strings.t("settings.barWidth")
            NumberField {
              value: root.visualizer.barWidth; from: 1; to: 12
              foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
              onModified: function (v) { root.saveSetting(root.visualizerId, "barWidth", v) }
            }
          }
          SettingRow {
            label: strings.t("settings.barSpacing")
            NumberField {
              value: root.visualizer.barSpacing; from: 0; to: 8
              foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
              onModified: function (v) { root.saveSetting(root.visualizerId, "barSpacing", v) }
            }
          }
          SettingRow {
            label: strings.t("settings.height")
            NumberField {
              value: root.visualizer.height; from: 20; to: 100; stepSize: 5
              foreground: root.foreground; fontFamily: root.fontFamily; fontSize: Style.font.bodySmall
              onModified: function (v) { root.saveSetting(root.visualizerId, "height", v) }
            }
          }
          SettingRow {
            label: strings.t("settings.gradient")
            ToggleSwitch {
              checked: root.visualizer.gradient
              foreground: root.foreground
              onToggled: root.saveSetting(root.visualizerId, "gradient", !root.visualizer.gradient)
            }
          }
          SettingRow {
            label: strings.t("settings.colors")
            TextField {
              width: parent.width
              text: root.visualizer.colors
              placeholderText: strings.t("settings.colorsTheme")
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onEditingFinished: if (text.trim() !== root.visualizer.colors) root.saveSetting(root.visualizerId, "colors", text.trim())
            }
          }
          SettingRow {
            label: strings.t("settings.hideWhenIdle")
            ToggleSwitch {
              checked: root.visualizer.hideWhenIdle
              foreground: root.foreground
              onToggled: root.saveSetting(root.visualizerId, "hideWhenIdle", !root.visualizer.hideWhenIdle)
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("settings.live")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // A labelled settings row: label on the left, the control on the right.
  component SettingRow: Item {
    id: settingRow
    property string label: ""
    default property alias control: holder.data
    width: parent ? parent.width : 0
    implicitHeight: Math.max(rowLabel.implicitHeight, holder.childrenRect.height)

    Text {
      id: rowLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.42
      textFormat: Text.PlainText
      text: settingRow.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
    Item {
      id: holder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.56
      height: childrenRect.height
    }
  }
}
