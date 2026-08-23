import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "sgruendel.airq"
  ipcTarget: "sgruendel.airq"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground

  property var readings: null
  property string devicePassword: ""
  property string fetchError: ""
  property bool fetching: false
  property bool stale: false
  property int retries: 0
  property real nowMs: Date.now()

  readonly property string configuredHost: String(setting("host", ""))
    .replace(/^https?:\/\//, "").replace(/\/+$/, "")
  readonly property string configuredSerial: String(setting("serial", ""))
  readonly property int refreshSeconds: Math.max(10, parseInt(setting("refreshSeconds", 30), 10) || 30)
  readonly property real warningThreshold: parseFloat(String(setting("radonWarning", 100))) || 100
  readonly property real indexGreenThreshold: Math.max(0, Math.min(100,
    parseFloat(String(setting("indexGreenThreshold", 80))) || 80))
  readonly property real indexYellowThreshold: Math.max(0, Math.min(indexGreenThreshold,
    parseFloat(String(setting("indexYellowThreshold", 60))) || 60))
  readonly property real radonValue: Model.number(readings, "radon")
  readonly property real healthIndex: Model.indexPercent(readings, "health")
  readonly property real performanceIndex: Model.indexPercent(readings, "performance")
  readonly property bool indexDataCurrent: readings !== null && !stale && fetchError === ""
  readonly property string healthState: indexDataCurrent
    ? Model.indexState(healthIndex, indexGreenThreshold, indexYellowThreshold) : "unavailable"
  readonly property string performanceState: indexDataCurrent
    ? Model.indexState(performanceIndex, indexGreenThreshold, indexYellowThreshold) : "unavailable"
  readonly property color healthColor: indexColor(healthState)
  readonly property color performanceColor: indexColor(performanceState)
  readonly property string radonState: Model.radonState(radonValue, warningThreshold)
  readonly property bool needsAttention: stale || fetchError !== ""
    || (isFinite(radonValue) && radonValue >= warningThreshold)
  readonly property string tooltipText: readings
    ? "Health: " + Model.score(readings, "health") + " (" + healthState + ")"
      + "\nPerformance: " + Model.score(readings, "performance") + " (" + performanceState + ")"
      + "\n" + Model.tooltipText(readings, nowMs, stale)
      + (fetchError !== "" ? "\n" + fetchError : "")
    : (fetchError !== "" ? "air-Q: " + fetchError : "air-Q: fetching…")
  readonly property var sensorCards: Model.metricRows(readings)
  readonly property var sensorStatus: Model.statusLines(readings)
  readonly property string measurementAge: readings
    ? Model.measurementAge(readings.timestamp, nowMs) : "unknown age"

  function indexColor(state) {
    if (state === "green") return "#4caf50"
    if (state === "yellow") return "#fbc02d"
    if (state === "red") return "#e53935"
    return "#6b7280"
  }

  function setCenterHoverRevealSuppressed(value) {
    if (bar && "centerHoverRevealSuppressed" in bar) bar.centerHoverRevealSuppressed = value
  }

  function open() {
    setCenterHoverRevealSuppressed(false)
    controller.show()
    refresh()
  }

  function openFromHotkey() {
    controller.show()
    refresh()
    Qt.callLater(function() {
      if (root.opened) root.setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    controller.hide()
  }

  function toggle() {
    if (opened) close()
    else openFromHotkey()
  }

  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refresh() {
    retries = 0
    fetch()
  }

  function fetch() {
    if (!configuredHost || !configuredSerial) {
      fetching = false
      fetchError = "Set the device host and serial number in widget settings"
      return
    }
    if (fetchProc.running || credentialProc.running) return
    if (!devicePassword) {
      fetching = true
      credentialProc.command = [
        "secret-tool", "lookup",
        "application", "omarchy-airq",
        "serial", configuredSerial
      ]
      credentialProc.running = true
      return
    }
    fetching = true
    fetchProc.command = ["curl", "-fsS", "--connect-timeout", "3", "--max-time", "8",
      "http://" + configuredHost + "/data/"]
    fetchProc.running = true
  }

  function applyDeviceResponse(raw) {
    fetching = false
    var parsed = Model.parseDataResponse(raw, devicePassword)
    if (!parsed) {
      scheduleRetry("Could not read or decrypt the air-Q response")
      return
    }
    readings = parsed
    stale = false
    retries = 0
    fetchError = ""
    nowMs = Date.now()
  }

  function scheduleRetry(message) {
    stale = readings !== null
    fetchError = message
    if (retries >= 3) return
    retries++
    fetchError = message + " · retry " + retries + "/3"
    retryTimer.restart()
  }

  onConfiguredHostChanged: Qt.callLater(refresh)
  onConfiguredSerialChanged: {
    devicePassword = ""
    Qt.callLater(refresh)
  }

  Process {
    id: credentialProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var secret = String(text || "").replace(/\r?\n$/, "")
        if (!secret) {
          root.fetching = false
          root.stale = root.readings !== null
          root.fetchError = "Device password is missing from the keyring"
          return
        }
        root.devicePassword = secret
        root.fetchError = ""
        Qt.callLater(root.fetch)
      }
    }
  }

  function openDevicePage() {
    openPageProc.command = ["xdg-open", "http://" + configuredHost + "/"]
    openPageProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyDeviceResponse(text)
    }
  }

  Process { id: openPageProc }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.fetch()
  }

  Timer {
    interval: root.refreshSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
        if (text === "o" || text === "O") root.openDevicePage()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: heroRow.implicitHeight

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(28)

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  text: "RADON"
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Row {
                  spacing: Style.space(5)
                  Text {
                    text: Model.reading(root.readings, "radon", root.radonValue < 10 ? 1 : 0, "").replace(" ", "")
                    color: root.needsAttention ? (root.bar ? root.bar.urgent : Color.urgent) : root.contentForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: 52
                    font.bold: true
                  }
                  Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(9)
                    text: "Bq/m³"
                    color: Qt.darker(root.contentForeground, 1.35)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: root.radonState.toUpperCase()
                  color: root.needsAttention ? (root.bar ? root.bar.urgent : Color.urgent) : root.contentForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: "Health " + Model.score(root.readings, "health")
                    + "   Performance " + Model.score(root.readings, "performance")
                  color: Qt.darker(root.contentForeground, 1.35)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: root.fetching ? "Refreshing…" : "Measured " + root.measurementAge
                  color: Qt.darker(root.contentForeground, 1.55)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }
          }

          Column {
            visible: root.sensorStatus.length > 0
            width: parent.width
            spacing: Style.space(5)

            Repeater {
              model: root.sensorStatus

              Text {
                required property string modelData
                width: parent.width
                text: modelData
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: Qt.darker(root.contentForeground, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
            }
          }

          Rectangle {
            visible: root.fetchError !== ""
            width: parent.width
            height: visible ? errorText.implicitHeight + Style.space(18) : 0
            radius: Style.cornerRadius
            color: Qt.rgba((root.bar ? root.bar.urgent : Color.urgent).r,
                           (root.bar ? root.bar.urgent : Color.urgent).g,
                           (root.bar ? root.bar.urgent : Color.urgent).b, 0.14)

            Text {
              id: errorText
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              text: root.fetchError
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Grid {
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 2
            spacing: Style.space(10)

            Repeater {
              model: root.sensorCards

              Rectangle {
                required property var modelData
                width: Style.space(224)
                height: Style.space(68)
                radius: Style.cornerRadius
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.055)

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Text {
                    text: parent.parent.modelData.label
                    color: Qt.darker(root.contentForeground, 1.45)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                  Text {
                    text: parent.parent.modelData.text
                    color: root.contentForeground
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.title
                  }
                }
              }
            }
          }

          Text {
            visible: root.readings !== null
            width: parent.width
            text: "Measured " + root.measurementAge + (root.stale ? " · stale" : "")
            color: Qt.darker(root.contentForeground, 1.55)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            text: "R refresh   ·   O open device   ·   Esc close"
            color: Qt.darker(root.contentForeground, 1.55)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
