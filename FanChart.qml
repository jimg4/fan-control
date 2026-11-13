import QtQuick
import qs.Commons
import qs.Commons as Commons

// Two views of the fan:
//   "curve"   Auto mode. Temperature on x, RPM on y: the speed the curve asks
//             for at every temperature, with the fan's live position on it.
//   "history" Other modes. The last few minutes of control temperature (line)
//             over fan speed (shaded), with the target and full-blast lines.
Canvas {
  id: root

  property string kind: "curve"
  property var temps: []
  property var rpms: []
  property int historyLength: 120
  property real fanMin: 1200
  property real fanMax: 7200
  property real rampStart: 55
  property real fullBlast: 85
  property real targetTemp: -1
  property real liveTemp: NaN
  property real liveRpm: NaN
  property real tempLow: 30
  property real tempHigh: 100

  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property color background: Commons.Color.background
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.caption
  // Whole strings from the plugin catalog, each with a %1 placeholder.
  property var labels: ({ ramp: "%1", blast: "%1", target: "%1", degrees: "%1", minutesAgo: "%1" })

  readonly property var paintKey: [kind, temps, rpms, fanMin, fanMax, rampStart, fullBlast, targetTemp,
    liveTemp, liveRpm, foreground, accent, urgent, background, fontFamily, fontSize, width, height, labels]
  onPaintKeyChanged: requestPaint()

  readonly property real padTop: fontSize + Style.space(6)
  readonly property real padBottom: fontSize + Style.space(6)

  function rgba(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function degrees(t) { return labels.degrees.arg(Commons.I18n.formatNumber(Math.round(t))) }

  function dashedLine(ctx, x1, y1, x2, y2, dash, gap) {
    var len = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1))
    if (len <= 0) return
    var dx = (x2 - x1) / len, dy = (y2 - y1) / len
    ctx.beginPath()
    for (var d = 0; d < len; d += dash + gap) {
      var e = Math.min(len, d + dash)
      ctx.moveTo(x1 + dx * d, y1 + dy * d)
      ctx.lineTo(x1 + dx * e, y1 + dy * e)
    }
    ctx.stroke()
  }

  function label(ctx, text, x, y, color, align) {
    ctx.fillStyle = color
    ctx.textAlign = align || "center"
    ctx.fillText(text, x, y)
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var w = width, h = height
    if (w <= 0 || h <= 0) return
    var top = padTop, bottom = h - padBottom, plotH = bottom - top
    var span = Math.max(1, tempHigh - tempLow)
    var rpmSpan = Math.max(1, fanMax - fanMin)
    function xT(t) { return (Math.max(tempLow, Math.min(tempHigh, t)) - tempLow) / span * w }
    function yT(t) { return bottom - (Math.max(tempLow, Math.min(tempHigh, t)) - tempLow) / span * plotH }
    function yR(r) { return bottom - Math.max(0, Math.min(1, (r - fanMin) / rpmSpan)) * plotH }

    ctx.font = "bold " + fontSize + "px \"" + fontFamily + "\""
    ctx.textBaseline = "alphabetic"
    ctx.lineCap = "round"
    ctx.lineJoin = "round"

    // Grid: quarter lines plus the baseline.
    ctx.strokeStyle = rgba(foreground, 0.07)
    ctx.lineWidth = 1
    for (var g = 0; g <= 4; g++) {
      var gy = Math.round(top + plotH * g / 4) + 0.5
      ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
    }

    var dim = rgba(foreground, 0.55)

    if (kind === "curve") {
      var pts = [[tempLow, fanMin], [rampStart, fanMin], [fullBlast, fanMax], [tempHigh, fanMax]]
      ctx.beginPath()
      ctx.moveTo(xT(pts[0][0]), bottom)
      for (var i = 0; i < pts.length; i++) ctx.lineTo(xT(pts[i][0]), yR(pts[i][1]))
      ctx.lineTo(w, bottom)
      ctx.closePath()
      ctx.fillStyle = rgba(accent, 0.14)
      ctx.fill()

      ctx.beginPath()
      for (var j = 0; j < pts.length; j++) {
        var px = xT(pts[j][0]), py = yR(pts[j][1])
        if (j === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
      }
      ctx.strokeStyle = foreground
      ctx.lineWidth = 2
      ctx.stroke()

      ctx.lineWidth = 1
      ctx.strokeStyle = rgba(foreground, 0.45)
      dashedLine(ctx, Math.round(xT(rampStart)) + 0.5, top, Math.round(xT(rampStart)) + 0.5, bottom, 3, 3)
      ctx.strokeStyle = rgba(urgent, 0.8)
      dashedLine(ctx, Math.round(xT(fullBlast)) + 0.5, top, Math.round(xT(fullBlast)) + 0.5, bottom, 3, 3)

      var rampX = xT(rampStart), blastX = xT(fullBlast)
      var rampText = labels.ramp.arg(degrees(rampStart)), blastText = labels.blast.arg(degrees(fullBlast))
      var rampW = ctx.measureText(rampText).width, blastW = ctx.measureText(blastText).width
      // Keep the two labels apart when the thresholds are close together.
      var rampLabelX = Math.max(rampW / 2, Math.min(rampX, blastX - (rampW + blastW) / 2 - Style.space(6)))
      var blastLabelX = Math.min(w - blastW / 2, Math.max(blastX, rampLabelX + (rampW + blastW) / 2 + Style.space(6)))
      label(ctx, rampText, rampLabelX, top - Style.space(4), dim)
      label(ctx, blastText, blastLabelX, top - Style.space(4), urgent)

      for (var t = 40; t < tempHigh; t += 20)
        label(ctx, degrees(t), xT(t), h - Style.space(1), rgba(foreground, 0.4))

      if (isFinite(liveTemp) && isFinite(liveRpm)) {
        var lx = xT(liveTemp), ly = yR(liveRpm)
        ctx.beginPath(); ctx.arc(lx, ly, 5.5, 0, Math.PI * 2)
        ctx.fillStyle = background; ctx.fill()
        ctx.beginPath(); ctx.arc(lx, ly, 4, 0, Math.PI * 2)
        ctx.fillStyle = accent; ctx.fill()
      }
      return
    }

    // History: newest sample at the right edge.
    var n = Math.max(2, historyLength)
    function xS(index, count) { return w - (count - 1 - index) / (n - 1) * w }

    if (rpms.length > 1) {
      ctx.beginPath()
      ctx.moveTo(xS(0, rpms.length), bottom)
      for (var a = 0; a < rpms.length; a++) ctx.lineTo(xS(a, rpms.length), yR(Number(rpms[a]) || fanMin))
      ctx.lineTo(xS(rpms.length - 1, rpms.length), bottom)
      ctx.closePath()
      ctx.fillStyle = rgba(accent, 0.16)
      ctx.fill()
    }

    ctx.lineWidth = 1
    ctx.strokeStyle = rgba(urgent, 0.8)
    dashedLine(ctx, 0, Math.round(yT(fullBlast)) + 0.5, w, Math.round(yT(fullBlast)) + 0.5, 3, 3)
    label(ctx, labels.blast.arg(degrees(fullBlast)), w - Style.space(2), yT(fullBlast) - Style.space(4), urgent, "right")
    if (targetTemp > 0) {
      ctx.strokeStyle = rgba(foreground, 0.5)
      dashedLine(ctx, 0, Math.round(yT(targetTemp)) + 0.5, w, Math.round(yT(targetTemp)) + 0.5, 3, 3)
      label(ctx, labels.target.arg(degrees(targetTemp)), Style.space(2), yT(targetTemp) - Style.space(4), dim, "left")
    }

    if (temps.length > 1) {
      ctx.beginPath()
      var started = false
      for (var b = 0; b < temps.length; b++) {
        var v = Number(temps[b])
        if (!isFinite(v)) { started = false; continue }
        if (!started) { ctx.moveTo(xS(b, temps.length), yT(v)); started = true }
        else ctx.lineTo(xS(b, temps.length), yT(v))
      }
      ctx.strokeStyle = foreground
      ctx.lineWidth = 2
      ctx.stroke()
    }

    label(ctx, labels.minutesAgo.arg(Commons.I18n.formatNumber(Math.round(n / 60))), Style.space(2), h - Style.space(1), rgba(foreground, 0.4), "left")
    if (temps.length > 0 && isFinite(Number(temps[temps.length - 1])))
      label(ctx, degrees(Number(temps[temps.length - 1])), w - Style.space(2), h - Style.space(1), dim, "right")
  }
}
