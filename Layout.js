.pragma library

// Spread windows over a W x H area without overlap, keeping aspect ratios.
// Tries every row count and keeps the one that lets thumbnails be largest.
// sizes: [{ w, h }] in screen pixels. Returns [{ x, y, w, h }] in the same
// order, relative to the area.
function spread(sizes, W, H, gap) {
  var n = sizes.length
  if (!n || W <= 0 || H <= 0) return []

  var best = null
  for (var rows = 1; rows <= n; rows++) {
    var per = Math.ceil(n / rows)
    var lines = []
    for (var i = 0; i < n; i += per) {
      var line = []
      for (var k = i; k < Math.min(i + per, n); k++) line.push(k)
      lines.push(line)
    }
    if (lines.length !== rows) continue

    var scale = 1, sumH = 0
    for (var l = 0; l < lines.length; l++) {
      var w = 0, h = 0
      for (var j = 0; j < lines[l].length; j++) {
        w += sizes[lines[l][j]].w
        h = Math.max(h, sizes[lines[l][j]].h)
      }
      scale = Math.min(scale, (W - gap * (lines[l].length - 1)) / w)
      sumH += h
    }
    scale = Math.min(scale, (H - gap * (rows - 1)) / sumH)
    if (!best || scale > best.scale + 0.001) best = { scale: scale, lines: lines }
  }

  var s = Math.max(0.05, best.scale)
  var out = new Array(n)
  var heights = best.lines.map(function (line) {
    return Math.max.apply(null, line.map(function (k) { return sizes[k].h * s }))
  })
  var totalH = heights.reduce(function (a, b) { return a + b }, 0) + gap * (heights.length - 1)
  var y = (H - totalH) / 2
  for (var r = 0; r < best.lines.length; r++) {
    var row = best.lines[r]
    var rowW = row.reduce(function (a, k) { return a + sizes[k].w * s }, 0) + gap * (row.length - 1)
    var x = (W - rowW) / 2
    for (var c = 0; c < row.length; c++) {
      var sz = sizes[row[c]]
      out[row[c]] = { x: x, y: y + (heights[r] - sz.h * s) / 2, w: sz.w * s, h: sz.h * s }
      x += sz.w * s + gap
    }
    y += heights[r] + gap
  }
  return out
}
