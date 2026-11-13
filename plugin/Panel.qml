import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// Bar widget + panel for the fanctl daemon (daemon/fanctl.py). The daemon
// publishes /run/fan-control/state.json once a second; settings go back
// through `fanctl set`, which edits /etc/fan-control/config.json.
Panel {
  id: root
  moduleName: "dimef.fan-control"
  ipcTarget: "dimef.fan-control"
  manageIpc: false

  readonly property string fanctl: "/usr/local/bin/fanctl"
  readonly property string statePath: "/run/fan-control/state.json"
  readonly property int historyLength: 120
  readonly property int overrideTtlMs: 4000

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- state
  property var state: null
  property real nowSeconds: Date.now() / 1000
  property real lastSampleTime: 0
  property var tempHistory: []
  property var rpmHistory: []
  property string lastError: ""

  // Edits shown before the daemon confirms them: { key: { value, at } }.
  property var overrides: ({})
  property real overrideClock: Date.now()
  property var pendingPairs: ({})

  // Live slider drag, previewed in the chart and labels before release.
  property string dragKey: ""
  property real dragValue: 0

  readonly property bool online: Model.isOnline(state, nowSeconds)
  readonly property var merged: Model.mergeOverrides(state ? state.config : null, overrides, overrideClock, overrideTtlMs)
  readonly property var cfg: Model.normalizeConfig(merged.config)
  readonly property var viewCfg: {
    if (dragKey === "") return cfg
    var c = Object.assign({}, cfg)
    c[dragKey] = dragValue
    return Model.normalizeConfig(c, dragKey)
  }
  readonly property var fan: state && state.fan ? state.fan : ({})
  readonly property var control: state && state.control ? state.control : null
  readonly property real fanMin: fan.min > 0 ? fan.min : 1200
  readonly property real fanMax: fan.max > fanMin ? fan.max : 7200
  readonly property real rpm: Number(fan.rpm) || 0
  readonly property int percent: Model.fanPercent(rpm, fanMin, fanMax)
  readonly property real controlTemp: control && control.temp !== null && control.temp !== undefined ? Number(control.temp) : NaN
  readonly property string controlSensorId: control && control.sensor ? control.sensor : cfg.sensor
  readonly property string controlSensorName: Model.sensorName(state, controlSensorId)
  readonly property bool overriding: online && control !== null && Model.isOverride(control.reason)
  readonly property var sensorList: state && Array.isArray(state.sensors) ? state.sensors.slice(0, 32) : []

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function deg(value) {
    return isFinite(value) ? strings.t("degrees").arg(Commons.I18n.formatNumber(Math.round(value))) : "--"
  }

  function ingest(text) {
    var parsed = Model.parseState(text)
    root.nowSeconds = Date.now() / 1000
    root.state = parsed
    root.overrideClock = Date.now()
    root.overrides = root.merged.overrides
    if (!parsed || parsed.time === root.lastSampleTime) return
    root.lastSampleTime = parsed.time
    var c = parsed.control
    root.tempHistory = Model.pushSample(root.tempHistory, c && c.temp !== null && c.temp !== undefined ? Number(c.temp) : NaN, historyLength)
    root.rpmHistory = Model.pushSample(root.rpmHistory, parsed.fan ? Number(parsed.fan.rpm) : NaN, historyLength)
  }

  // ------------------------------------------------------------- commands
  function apply(changes) {
    var now = Date.now()
    var next = Object.assign({}, root.overrides)
    for (var key in changes) {
      next[key] = { value: changes[key], at: now }
      root.pendingPairs[key] = changes[key]
    }
    root.overrideClock = now
    root.overrides = next
    flush()
  }

  // Set one value the way the daemon will normalize it, sending every key
  // the change moves (raising "ramp up" past "full blast" moves both).
  function setValue(key, value) {
    var c = Object.assign({}, root.cfg)
    c[key] = value
    var next = Model.normalizeConfig(c, key)
    var changes = {}
    for (var k in next) if (next[k] !== root.cfg[k]) changes[k] = next[k]
    if (Object.keys(changes).length) apply(changes)
  }

  function setMode(mode) {
    if (Model.MODES.indexOf(mode) >= 0 && mode !== root.cfg.mode) apply({ mode: mode })
  }

  function setSensor(id) {
    if (id && id !== root.cfg.sensor) apply({ sensor: id })
  }

  function flush() {
    if (setProc.running) return
    var args = [root.fanctl, "set"]
    for (var key in root.pendingPairs) args.push(key, String(root.pendingPairs[key]))
    if (args.length === 2) return
    root.pendingPairs = ({})
    setProc.command = args
    setProc.running = true
  }

  Process {
    id: setProc
    stderr: StdioCollector { id: setErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lastError = exitCode === 0 ? "" : String(setErr.text || "").trim().slice(0, 200)
      root.flush()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    onLoaded: root.ingest(text())
    onLoadFailed: root.ingest("")
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: stateFile.reload()
  }

  // ------------------------------------------------------------------ IPC
  ShellIpc {
    target: "dimef.fan-control"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function mode(name: string): string { root.setMode(name); return root.cfg.mode }
    function state(): string { return JSON.stringify(root.state) }
  }

  // ------------------------------------------------------- keyboard cursor
  // Sections, top to bottom: "mode" (h/l over the four modes), one
  // "slider:<key>" per slider (h/l nudges it), "sensors" (2-column grid).
  property string focusSection: "mode"
  property int selectedIndex: 0
  property bool cursorActive: false
  property real wheelAccumulator: 0

  readonly property var sliderKeys: online ? Model.slidersFor(cfg.mode) : []
  readonly property var visibleSections: {
    if (!online) return []
    var list = ["mode"]
    for (var i = 0; i < sliderKeys.length; i++) list.push("slider:" + sliderKeys[i])
    if (sensorList.length) list.push("sensors")
    return list
  }

  function enterSection(section, fromBelow) {
    focusSection = section
    if (section === "mode") selectedIndex = Math.max(0, Model.MODES.indexOf(cfg.mode))
    else if (section === "sensors") selectedIndex = fromBelow ? sensorList.length - 1 : 0
    else selectedIndex = -1
  }

  function moveCursor(dy) {
    var sections = visibleSections
    var s = sections.indexOf(focusSection)
    if (s < 0) { if (sections.length) enterSection(sections[0], false); return }
    if (focusSection === "sensors") {
      var next = selectedIndex + dy * 2
      if (next >= 0 && next < sensorList.length) { selectedIndex = next; return }
      if (next >= sensorList.length) return
    }
    var target = s + dy
    if (target >= 0 && target < sections.length) enterSection(sections[target], dy < 0)
  }

  function moveCursorH(dx) {
    if (focusSection === "mode") {
      selectedIndex = Math.max(0, Math.min(Model.MODES.length - 1, selectedIndex + dx))
    } else if (focusSection === "sensors") {
      selectedIndex = Math.max(0, Math.min(sensorList.length - 1, selectedIndex + dx))
    } else if (focusSection.indexOf("slider:") === 0) {
      var key = focusSection.slice(7)
      setValue(key, cfg[key] + dx * Model.sliderStep(key))
    }
  }

  function activateCursor() {
    if (focusSection === "mode") setMode(Model.MODES[selectedIndex])
    else if (focusSection === "sensors" && sensorList[selectedIndex]) setSensor(sensorList[selectedIndex].id)
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections.length) return
    if (sections.indexOf(focusSection) < 0) { enterSection(sections[0], false); return }
    if (focusSection === "sensors" && selectedIndex >= sensorList.length) selectedIndex = sensorList.length - 1
  }

  onVisibleSectionsChanged: clampCursor()

  onOpenedChanged: {
    if (!opened) return
    stateFile.reload()
    enterSection("mode", false)
    cursorActive = false
  }

  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var margin = 6
    if (pt.y < flick.contentY + margin) flick.contentY = Math.max(0, pt.y - margin)
    else if (pt.y + item.height > flick.contentY + flick.height - margin)
      flick.contentY = pt.y + item.height + margin - flick.height
  }

  // ------------------------------------------------------------- strings
  function modeLabel(mode) { return strings.t("mode." + mode) }

  function statusText() {
    if (!online) return ""
    var reason = control ? control.reason : ""
    var c = viewCfg
    if (reason === "full-blast") return strings.t("status.fullBlast").arg(controlSensorName).arg(deg(c.fullBlast))
    if (reason === "hard-limit") return strings.t("status.hardLimit").arg(deg(state.hardLimit))
    if (reason === "sensor-lost") return strings.t("status.sensorLost").arg(Model.sensorName(state, cfg.sensor))
    if (c.mode === "auto") return strings.t("status.auto").arg(deg(c.rampStart)).arg(deg(c.fullBlast))
    if (c.mode === "target") return strings.t("status.target").arg(controlSensorName).arg(deg(c.targetTemp)).arg(deg(controlTemp))
    if (c.mode === "manual")
      return strings.t("status.manual").arg(Commons.I18n.formatNumber(c.manualRpm)).arg(controlSensorName).arg(deg(c.fullBlast))
    return strings.t("status.system")
  }

  function sliderValueText(key, value) {
    if (key === "manualRpm")
      return strings.t("rpm").arg(Commons.I18n.formatNumber(Math.round(value))) + "  ·  "
        + strings.t("percent").arg(Commons.I18n.formatNumber(Model.fanPercent(value, fanMin, fanMax)))
    return deg(value)
  }

  function barLabel() {
    var kind = String(root.setting("label", "none"))
    if (!online) return ""
    if (kind === "temp") return deg(controlTemp)
    if (kind === "rpm") return Commons.I18n.formatNumber(Math.round(rpm))
    return ""
  }

  function tooltip() {
    if (!online) return strings.t("tooltip.offline")
    return strings.t("tooltip").arg(Commons.I18n.formatNumber(Math.round(rpm))).arg(controlSensorName)
      .arg(deg(controlTemp)).arg(modeLabel(cfg.mode))
  }

  // ------------------------------------------------------------- bar icon
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  TextMetrics {
    id: barLabelMetrics
    font.family: button.fontFamily
    font.pixelSize: button.fontSize
    text: button.labelText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barGlyph(root.online, root.state)
    labelText: root.barLabel()
    fixedWidth: vertical ? -1 : (labelText !== "" ? slotSize + barLabelMetrics.advanceWidth + Style.space(4) : slotSize)
    active: root.overriding
    dimmed: !root.online
    tooltipText: root.tooltip()
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.online) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      if (root.cfg.mode === "manual") root.setValue("manualRpm", root.cfg.manualRpm + wheel.steps * 100)
      else if (root.cfg.mode === "target") root.setValue("targetTemp", root.cfg.targetTemp + wheel.steps)
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            foreground: root.fg
            fontFamily: root.fontFamily
            title: root.online ? strings.t("rpm").arg(Commons.I18n.formatNumber(Math.round(root.rpm))) : strings.t("title")
            meta: root.online
              ? root.controlSensorName + "  " + root.deg(root.controlTemp)
              : strings.t("offline.title")
            detail: root.online ? root.modeLabel(root.cfg.mode) : ""
            iconComponent: Component {
              Text {
                id: heroGlyph
                textFormat: Text.PlainText
                text: root.online ? Model.GLYPH.fan : Model.GLYPH.off
                color: root.overriding ? Commons.Color.urgent : root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                // Spins at a pace that tracks the real fan, but only while
                // the panel is open and animations are on.
                FrameAnimation {
                  running: root.opened && root.online && root.rpm > 0 && Style.duration(1000) > 0
                  onTriggered: heroGlyph.rotation = (heroGlyph.rotation + frameTime * 360 * root.rpm / 2400) % 360
                }
              }
            }
          }

          // ---------- Offline ----------
          Column {
            visible: !root.online
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: strings.t("offline.body")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---------- Chart + status ----------
          Column {
            visible: root.online
            width: parent.width
            spacing: Style.space(8)

            FanChart {
              width: parent.width
              height: Style.space(118)
              kind: root.viewCfg.mode === "auto" ? "curve" : "history"
              temps: root.tempHistory
              rpms: root.rpmHistory
              historyLength: root.historyLength
              fanMin: root.fanMin
              fanMax: root.fanMax
              rampStart: root.viewCfg.rampStart
              fullBlast: root.viewCfg.fullBlast
              targetTemp: root.viewCfg.mode === "target" ? root.viewCfg.targetTemp : -1
              liveTemp: root.controlTemp
              liveRpm: root.rpm
              foreground: root.fg
              accent: Commons.Color.accent
              urgent: Commons.Color.urgent
              background: root.bar ? root.bar.background : Commons.Color.background
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              labels: ({
                ramp: strings.t("chart.ramp"),
                blast: strings.t("chart.blast"),
                target: strings.t("chart.target")
              })
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.statusText()
              color: root.overriding ? Commons.Color.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              visible: root.lastError !== "" || (root.state && root.state.error)
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: root.lastError !== "" ? strings.t("error.write").arg(root.lastError) : String(root.state && root.state.error || "")
              color: Commons.Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Mode ----------
          PanelSeparator { visible: root.online; foreground: root.fg }

          Grid {
            id: modeRow
            visible: root.online
            width: parent.width
            columns: Model.MODES.length
            spacing: Style.spacing.xs
            readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

            Repeater {
              model: Model.MODES

              Button {
                id: modeButton
                required property string modelData
                required property int index

                width: modeRow.cellWidth
                text: root.modeLabel(modelData)
                tooltipText: strings.t("mode." + modelData + ".tip")
                fontSize: Style.font.caption
                foreground: root.fg
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.sm
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                selected: root.cfg.mode === modelData
                hasCursor: root.cursorActive && root.focusSection === "mode" && root.selectedIndex === index
                onClicked: root.setMode(modelData)
                onHovered: function(isHovered) {
                  if (!isHovered) return
                  root.cursorActive = true
                  root.focusSection = "mode"
                  root.selectedIndex = modeButton.index
                }
              }
            }
          }

          // ---------- Sliders ----------
          Column {
            visible: root.online && root.sliderKeys.length > 0
            width: parent.width
            spacing: Style.space(10)

            Repeater {
              model: root.sliderKeys

              SliderRow {
                required property string modelData
                width: panelColumn.width
                key: modelData
              }
            }
          }

          // ---------- Sensors ----------
          PanelSeparator { visible: root.online && root.sensorList.length > 0; foreground: root.fg }

          Column {
            visible: root.online && root.sensorList.length > 0
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: sensorsHeader.implicitHeight

              PanelSectionHeader {
                id: sensorsHeader
                text: strings.t("sensors")
                foreground: root.fg
                fontFamily: root.fontFamily
                anchors.left: parent.left
              }

              Text {
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.baseline: sensorsHeader.baseline
                textFormat: Text.PlainText
                text: strings.t("sensors.hint")
                color: Qt.darker(root.fg, 1.8)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
                width: Math.min(implicitWidth, parent.width - sensorsHeader.implicitWidth - Style.space(12))
                horizontalAlignment: Text.AlignRight
              }
            }

            Grid {
              id: sensorGrid
              width: parent.width
              columns: 2
              columnSpacing: Style.spacing.xs
              rowSpacing: Style.spacing.xs
              readonly property real cellWidth: (width - columnSpacing) / 2

              Repeater {
                model: root.sensorList

                SensorCell {
                  required property var modelData
                  required property int index
                  width: sensorGrid.cellWidth
                  sensor: modelData
                  cellIndex: index
                }
              }
            }
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }

  // ----------------------------------------------------------- components
  component SliderRow: Column {
    id: sliderRow
    required property string key
    readonly property string section: "slider:" + key
    readonly property var range: Model.sliderRange(key, root.fan)
    readonly property real shown: root.dragKey === key ? root.dragValue : root.viewCfg[key]

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(sliderHeader.implicitHeight, sliderValue.implicitHeight)

      PanelSectionHeader {
        id: sliderHeader
        text: strings.t("slider." + sliderRow.key)
        foreground: root.fg
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: sliderValue
        textFormat: Text.PlainText
        text: root.sliderValueText(sliderRow.key, sliderRow.shown)
        color: sliderRow.key === "fullBlast" ? Commons.Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    CursorSurface {
      id: sliderSurface
      width: parent.width
      height: slider.implicitHeight + Style.spacing.controlGap
      hasCursor: root.cursorActive && root.focusSection === sliderRow.section
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderSurface)
      foreground: root.fg
      outline: true

      PanelSlider {
        id: slider
        bar: root.bar
        anchors.fill: parent
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        minimum: sliderRow.range[0]
        maximum: sliderRow.range[1]
        step: Model.sliderStep(sliderRow.key)
        integer: true
        value: root.viewCfg[sliderRow.key]
        onMoved: function(v) {
          var s = Model.sliderStep(sliderRow.key)
          root.dragKey = sliderRow.key
          root.dragValue = Math.round(v / s) * s
        }
        onReleased: function(v) {
          var s = Model.sliderStep(sliderRow.key)
          root.dragKey = ""
          root.setValue(sliderRow.key, Math.round(v / s) * s)
        }
      }

      HoverHandler {
        onHoveredChanged: if (hovered) {
          root.cursorActive = true
          root.focusSection = sliderRow.section
          root.selectedIndex = -1
        }
      }
    }
  }

  component SensorCell: CursorSurface {
    id: cell
    required property var sensor
    required property int cellIndex
    readonly property bool controlling: root.cfg.sensor === sensor.id

    hasCursor: root.cursorActive && root.focusSection === "sensors" && root.selectedIndex === cellIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(cell)
    current: controlling
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Commons.Color.accent)
    currentFill: Style.selectedFillFor(root.fg, Commons.Color.accent)
    implicitHeight: cellName.implicitHeight + Style.spacing.lg

    Text {
      id: cellName
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: cellTemp.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: String(cell.sensor.name || cell.sensor.id)
      elide: Text.ElideRight
      color: cell.controlling ? root.fg : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: cell.controlling
    }

    Text {
      id: cellTemp
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.deg(Number(cell.sensor.temp))
      color: Number(cell.sensor.temp) >= root.viewCfg.fullBlast ? Commons.Color.urgent : root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "sensors"
        root.selectedIndex = cell.cellIndex
      }
      onClicked: root.setSensor(cell.sensor.id)
    }
  }
}
