import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "sgruendel.airq"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color healthyColor: "#4caf50"
  readonly property color warningColor: "#fbc02d"
  readonly property color criticalColor: bar ? bar.urgent : Color.urgent
  readonly property color unavailableColor: Color.muted
  readonly property int maxResponseBytes: 64 * 1024

  property var readings: null
  property string devicePassword: ""
  property string fetchError: ""
  property bool fetching: false
  property bool stale: false
  property int retries: 0
  property real nowMs: Date.now()
  property bool credentialTimedOut: false
  property bool fetchTimedOut: false

  readonly property string configuredHost: String(setting("host", ""))
    .replace(/^https?:\/\//, "").replace(/\/+$/, "")
  readonly property string configuredSerial: String(setting("serial", ""))
  readonly property int refreshSeconds: integerSetting("refreshSeconds", 30, 10, 3600)
  readonly property int warningThreshold: integerSetting("radonWarning", 100, 10, 10000)
  readonly property int indexGreenThreshold: integerSetting("indexGreenThreshold", 80, 0, 100)
  readonly property int indexYellowThreshold: Math.min(indexGreenThreshold,
    integerSetting("indexYellowThreshold", 60, 0, 100))
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
  readonly property string tooltipPlainText: readings
    ? "Health: " + Model.score(readings, "health") + " (" + healthState + ")"
      + "\nPerformance: " + Model.score(readings, "performance") + " (" + performanceState + ")"
      + "\n" + Model.tooltipText(readings, nowMs, stale)
      + (fetchError !== "" ? "\n" + fetchError : "")
    : (fetchError !== "" ? "air-Q: " + fetchError : "air-Q: fetching…")
  // The bar owns the tooltip Text item and leaves it in AutoText mode. Supply
  // an escaped rich-text document so device/error strings stay inert there.
  readonly property string tooltipText: Model.inertTooltipText(tooltipPlainText)
  readonly property var sensorCards: Model.metricRows(readings)
  readonly property var sensorStatus: Model.statusLines(readings)
  readonly property string measurementAge: readings
    ? Model.measurementAge(readings.timestamp, nowMs) : "unknown age"

  function integerSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function indexColor(state) {
    if (state === "green") return healthyColor
    if (state === "yellow") return warningColor
    if (state === "red") return criticalColor
    return unavailableColor
  }

  function setCenterHoverRevealSuppressed(value) {
    if (bar && "centerHoverRevealSuppressed" in bar) bar.centerHoverRevealSuppressed = value
  }

  function open() {
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
    else open()
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

  function failNow(message) {
    fetching = false
    stale = readings !== null
    fetchError = message
  }

  function processError(raw, fallback) {
    var lines = String(raw || "").trim().split(/\r?\n/)
    return lines[0] ? fallback + ": " + lines[0] : fallback
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
      credentialTimedOut = false
      credentialTimeout.restart()
      credentialProc.running = true
      return
    }
    fetching = true
    fetchProc.command = ["curl", "-fsS", "--connect-timeout", "3", "--max-time", "8",
      "--max-filesize", String(maxResponseBytes),
      "http://" + configuredHost + "/data/"]
    fetchTimedOut = false
    fetchTimeout.restart()
    fetchProc.running = true
  }

  function applyDeviceResponse(raw) {
    fetching = false
    var parsed = Model.parseDataResponse(raw, devicePassword)
    if (!parsed) {
      devicePassword = ""
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
    fetching = false
    stale = readings !== null
    if (retries >= 3) {
      fetchError = message
      return
    }
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
    stdout: StdioCollector { id: credentialStdout; waitForEnd: true }
    stderr: StdioCollector { id: credentialStderr; waitForEnd: true }
    onExited: function(exitCode) {
      credentialTimeout.stop()
      if (root.credentialTimedOut) {
        root.credentialTimedOut = false
        return
      }
      var secret = String(credentialStdout.text || "").replace(/\r?\n$/, "")
      if (exitCode !== 0 || !secret) {
        root.failNow(root.processError(credentialStderr.text,
          "Device password is missing or secret-tool/keyring is unavailable"))
        return
      }
      root.devicePassword = secret
      root.fetchError = ""
      Qt.callLater(root.fetch)
    }
  }

  function openDevicePage() {
    openPageProc.command = ["xdg-open", "http://" + configuredHost + "/"]
    openPageProc.running = true
  }

  Process {
    id: fetchProc
    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }
    onExited: function(exitCode) {
      fetchTimeout.stop()
      if (root.fetchTimedOut) {
        root.fetchTimedOut = false
        return
      }
      if (exitCode === 63) {
        root.scheduleRetry("air-Q response exceeded the 64 KiB limit")
        return
      }
      if (exitCode !== 0) {
        root.scheduleRetry(root.processError(fetchStderr.text, "air-Q request failed"))
        return
      }
      root.applyDeviceResponse(fetchStdout.text)
    }
  }

  Process { id: openPageProc }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.fetch()
  }

  Timer {
    id: credentialTimeout
    interval: 10000
    onTriggered: {
      root.credentialTimedOut = true
      credentialProc.running = false
      root.failNow("secret-tool did not start or respond within 10 seconds")
    }
  }

  Timer {
    id: fetchTimeout
    interval: 10000
    onTriggered: {
      root.fetchTimedOut = true
      fetchProc.running = false
      root.scheduleRetry("air-Q request timed out")
    }
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
                  color: Qt.darker(root.barForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Row {
                  spacing: Style.space(5)
                  Text {
                    text: Model.reading(root.readings, "radon", root.radonValue < 10 ? 1 : 0, "")
                    color: root.needsAttention ? root.criticalColor : root.barForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: 52
                    font.bold: true
                  }
                  Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(9)
                    text: "Bq/m³"
                    color: Qt.darker(root.barForeground, 1.35)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: root.radonState.toUpperCase()
                  color: root.needsAttention ? root.criticalColor : root.barForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  text: "Health " + Model.score(root.readings, "health")
                    + "   Performance " + Model.score(root.readings, "performance")
                  color: Qt.darker(root.barForeground, 1.35)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: root.fetching ? "Refreshing…" : "Measured " + root.measurementAge
                  color: Qt.darker(root.barForeground, 1.55)
                  font.family: root.contentFontFamily
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
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: Qt.darker(root.barForeground, 1.35)
                font.family: root.contentFontFamily
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
            color: Qt.rgba(root.criticalColor.r, root.criticalColor.g,
                           root.criticalColor.b, 0.14)

            Text {
              id: errorText
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              text: root.fetchError
              textFormat: Text.PlainText
              color: root.criticalColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.barForeground
            opacity: 0.12
          }

          Grid {
            anchors.horizontalCenter: parent.horizontalCenter
            columns: 2
            spacing: Style.space(10)

            Repeater {
              model: root.sensorCards

              Rectangle {
                id: sensorCard
                required property var modelData
                width: Style.space(224)
                height: Style.space(68)
                radius: Style.cornerRadius
                color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.055)

                Column {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(14)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  Text {
                    text: sensorCard.modelData.label
                    color: Qt.darker(root.barForeground, 1.45)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                  Text {
                    text: sensorCard.modelData.text
                    color: root.barForeground
                    font.family: root.contentFontFamily
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
            color: Qt.darker(root.barForeground, 1.55)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            text: "R refresh   ·   O open device   ·   Esc close"
            color: Qt.darker(root.barForeground, 1.55)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
