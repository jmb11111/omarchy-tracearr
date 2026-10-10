import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Tracearr for the Omarchy bar: a pill with the active stream count and a
// popup listing who is watching what, plus today's totals. Data comes from
// Tracearr's public API (/api/v1/public/streams and /stats/today).
Panel {
  id: root
  moduleName: "jmb11111.tracearr"
  ipcTarget: "tracearr"
  manageIpc: false

  // ------------------------------------------------------------------ theme

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // --------------------------------------------------------------- settings

  readonly property string url: String(setting("url", ""))
  readonly property string apiKey: String(setting("apiKey", ""))
  readonly property int pollSeconds: Model.clampInt(setting("pollSeconds", 15), 5, 3600, 15)
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property bool showPosters: setting("showPosters", true) !== false
  readonly property string icon: String(setting("icon", String.fromCodePoint(0xF06BA)))
  readonly property bool allowStop: setting("allowStop", true) !== false
  readonly property string stopMessage: String(setting("stopMessage", "This stream was stopped by the server admin."))
  readonly property bool configured: Model.baseUrl(url) !== "" && apiKey !== ""

  // ------------------------------------------------------------------- data

  property var result: null
  property string errorText: ""
  property double fetchedAtMs: 0
  property double nowMs: Date.now()
  property bool refreshQueued: false

  readonly property var streams: result ? result.streams : []
  readonly property int streamCount: streams.length
  readonly property int transcodeCount: result && result.summary ? Model.num(result.summary.transcodes) : 0
  readonly property bool hasError: configured && errorText !== ""
  readonly property bool busy: fetchProc.running

  function refresh() {
    if (!configured) return
    if (fetchProc.running) { refreshQueued = true; return }
    fetchProc.command = Model.fetchCommand(url)
    fetchProc.environment = { TRACEARR_KEY: apiKey }
    fetchProc.running = true
  }

  onUrlChanged: { result = null; errorText = ""; Qt.callLater(refresh) }
  onApiKeyChanged: { result = null; errorText = ""; Qt.callLater(refresh) }

  Process {
    id: fetchProc
    running: false

    stdout: StdioCollector { id: outCollector; waitForEnd: true }
    stderr: StdioCollector { id: errCollector; waitForEnd: true }

    onExited: function(exitCode, exitStatus) {
      var parsed = Model.parseOutput(outCollector.text, errCollector.text)
      if (parsed.ok) {
        root.result = parsed
        root.errorText = ""
        root.fetchedAtMs = Date.now()
        root.nowMs = root.fetchedAtMs
      } else {
        root.errorText = parsed.error
      }
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  // ------------------------------------------------------------ stop stream

  property string armedStreamId: ""
  property string stoppingStreamId: ""
  property string stopError: ""

  // First click arms, second click (within 4s) stops.
  function requestStop(streamId) {
    if (!configured || stopProc.running || streamId === "") return
    if (armedStreamId !== streamId) {
      armedStreamId = streamId
      stopError = ""
      disarmTimer.restart()
      return
    }
    armedStreamId = ""
    disarmTimer.stop()
    stoppingStreamId = streamId
    stopProc.command = Model.terminateCommand(url, streamId, stopMessage)
    stopProc.environment = { TRACEARR_KEY: apiKey }
    stopProc.running = true
  }

  Timer {
    id: disarmTimer
    interval: 4000
    onTriggered: root.armedStreamId = ""
  }

  Process {
    id: stopProc
    running: false

    stdout: StdioCollector { id: stopOut; waitForEnd: true }
    stderr: StdioCollector { id: stopErr; waitForEnd: true }

    onExited: function(exitCode, exitStatus) {
      var r = Model.parseTerminate(stopOut.text, stopErr.text)
      root.stopError = r.ok ? "" : "Couldn't stop stream: " + r.error
      root.stoppingStreamId = ""
      // The media server takes a moment to drop the session.
      afterStopRefresh.restart()
    }
  }

  Timer {
    id: afterStopRefresh
    interval: 1500
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Ticks progress bars between polls while the popup is open.
  Timer {
    interval: 1000
    running: root.opened && root.streamCount > 0
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: {
    armedStreamId = ""
    stopError = ""
    if (!opened) return
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function count(): string { return String(root.streamCount) }
    function status(): string {
      return root.errorText !== "" ? "error: " + root.errorText
        : root.result ? "ok: " + root.streamCount + " streams, fetched " + new Date(root.fetchedAtMs).toISOString()
        : "no data yet"
    }
  }

  // -------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    concealed: root.hideWhenIdle && root.configured && !root.hasError && root.streamCount === 0
    dimmed: !root.configured || root.streamCount === 0
    tooltipText: Model.tooltipLines(root.result, root.configured, root.errorText)
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(content.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Grid {
      id: content
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 3
      rows: root.vertical ? 3 : 1
      columnSpacing: Style.space(5)
      rowSpacing: Style.space(3)
      verticalItemAlignment: Grid.AlignVCenter
      horizontalItemAlignment: Grid.AlignHCenter

      Text {
        textFormat: Text.PlainText
        text: root.icon
        color: root.hasError ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Text {
        textFormat: Text.PlainText
        visible: root.streamCount > 0
        text: String(root.streamCount)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      // Transcoding indicator.
      Rectangle {
        visible: root.transcodeCount > 0
        width: Style.space(5)
        height: width
        radius: width / 2
        color: root.urgent
      }
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "o" && root.configured) Qt.openUrlExternally(Model.baseUrl(root.url))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Tracearr"
            meta: root.result ? (root.streamCount > 0 ? Model.summaryText(root.result.summary) : "Nothing playing") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.icon
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.busy ? "Refreshing…" : "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.busy
                  onClicked: root.refresh()
                }

                PanelActionButton {
                  iconText: "󰏌"
                  tooltipText: "Open Tracearr (o)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: root.configured
                  onClicked: { Qt.openUrlExternally(Model.baseUrl(root.url)); root.close() }
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Errors / setup hints.
          Text {
            textFormat: Text.PlainText
            visible: !root.configured || root.hasError
            width: parent.width
            text: !root.configured
              ? "Set \"url\" and \"apiKey\" on this widget's entry in ~/.config/omarchy/shell.json. Generate a key in Tracearr under Settings → General."
              : root.errorText
            color: root.configured ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.stopError !== ""
            width: parent.width
            text: root.stopError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.streams

            StreamCard {
              required property var modelData
              width: panelColumn.width
              stream: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.configured && root.result !== null && root.streamCount === 0
            width: parent.width
            text: "No one is watching right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          PanelSeparator {
            foreground: root.foreground
            visible: root.result !== null && root.result.today !== null
          }

          // Today's totals.
          Row {
            visible: root.result !== null && root.result.today !== null
            width: parent.width

            Repeater {
              model: root.result && root.result.today ? [
                { label: "Plays", value: String(Model.num(root.result.today.todayPlays)) },
                { label: "Watched", value: Model.num(root.result.today.watchTimeHours).toFixed(1) + "h" },
                { label: "Users", value: String(Model.num(root.result.today.activeUsersToday)) },
                { label: "Alerts", value: String(Model.num(root.result.today.alertsLast24h)) }
              ] : []

              Column {
                required property var modelData
                width: panelColumn.width / 4
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: parent.modelData.value
                  color: parent.modelData.label === "Alerts" && parent.modelData.value !== "0" ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: parent.modelData.label + (parent.modelData.label === "Alerts" ? " (24h)" : " today")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  // One active stream: poster, user, title, quality, progress.
  component StreamCard: Row {
    id: card
    property var stream: null

    readonly property bool paused: stream && stream.state === "paused"
    readonly property string kind: stream ? Model.decision(stream) : "play"
    readonly property real fraction: stream ? Model.progressFraction(stream, root.fetchedAtMs, root.nowMs) : 0

    spacing: Style.space(10)

    Rectangle {
      id: poster
      visible: root.showPosters
      width: Style.space(44)
      height: Math.round(width * 1.5)
      radius: Style.space(3)
      color: root.track
      clip: true

      Image {
        anchors.fill: parent
        source: card.stream ? Model.absoluteUrl(root.url, card.stream.posterUrl) : ""
        sourceSize.width: 96
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        smooth: true
      }
    }

    Column {
      width: card.width - (poster.visible ? poster.width + card.spacing : 0)
      spacing: Style.space(3)

      Item {
        width: parent.width
        implicitHeight: Math.max(userText.implicitHeight, badge.implicitHeight)

        Text {
          id: userText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: badge.left
          anchors.rightMargin: Style.spacing.sm
          anchors.verticalCenter: parent.verticalCenter
          text: (card.paused ? "󰏤  " : "󰐊  ") + Model.userName(card.stream)
          color: card.paused ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Rectangle {
          id: badge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: badgeText.implicitWidth + Style.space(10)
          implicitHeight: badgeText.implicitHeight + Style.space(3)
          width: implicitWidth
          height: implicitHeight
          radius: height / 2
          color: "transparent"
          border.width: 1
          border.color: card.kind === "transcode" ? root.urgent : root.dim

          Text {
            id: badgeText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: card.stream ? Model.decisionLabel(card.stream) : ""
            color: card.kind === "transcode" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: Model.primaryTitle(card.stream)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: Model.secondaryTitle(card.stream)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: card.stream ? Model.qualityLine(card.stream) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: text !== ""
        text: card.stream ? Model.deviceLine(card.stream) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Item { width: 1; height: Style.space(2) }

      Item {
        width: parent.width
        implicitHeight: Style.space(4)

        Rectangle {
          id: meterTrack
          anchors.fill: parent
          radius: height / 2
          color: root.track
        }

        Rectangle {
          anchors.left: meterTrack.left
          anchors.verticalCenter: meterTrack.verticalCenter
          height: meterTrack.height
          radius: meterTrack.radius
          width: Math.max(height, meterTrack.width * card.fraction)
          color: card.paused ? root.dim : root.foreground

          Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        }
      }

      Item {
        width: parent.width
        implicitHeight: Math.max(timeText.implicitHeight, stopButton.visible ? stopButton.implicitHeight : 0)

        // Stop control: first click arms ("Stop?"), second click stops.
        Rectangle {
          id: stopButton
          readonly property bool armed: card.stream && root.armedStreamId === card.stream.id
          readonly property bool stopping: card.stream && root.stoppingStreamId === card.stream.id
          visible: root.allowStop && card.stream !== null
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: stopLabel.implicitWidth + Style.space(12)
          implicitHeight: stopLabel.implicitHeight + Style.space(4)
          width: implicitWidth
          height: implicitHeight
          radius: height / 2
          color: armed ? root.urgent : "transparent"
          border.width: 1
          border.color: armed || stopMouse.containsMouse ? root.urgent : root.dim

          Text {
            id: stopLabel
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: stopButton.stopping ? "Stopping…"
              : stopButton.armed ? String.fromCodePoint(0xF04DB) + " Stop stream?"
              : String.fromCodePoint(0xF04DB) + " Stop"
            color: stopButton.armed ? Color.background : (stopMouse.containsMouse ? root.urgent : root.dim)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            id: stopMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: !stopButton.stopping
            onClicked: root.requestStop(String(card.stream.id))
          }
        }

        Text {
          id: timeText
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: card.stream !== null && Model.num(card.stream.durationMs) > 0
          text: card.stream
            ? Model.formatClock(Model.progressMs(card.stream, root.fetchedAtMs, root.nowMs)) + " / " + Model.formatClock(card.stream.durationMs)
            : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
