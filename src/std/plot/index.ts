import fs from 'hao:fs'

interface TensorLike {
  readonly shape: number[]
}

interface TensorModule {
  tensor(data: number | number[] | number[][], opts?: { dtype?: string }): TensorLike
}

interface FsModule {
  readFileSync(path: string): string
  writeFileSync(path: string, data: string): void
}

interface PlotOpts {
  color?: string
  label?: string
  lineWidth?: number
  markerSize?: number
}

interface BarOpts {
  color?: string
  label?: string
  width?: number
}

interface FigureOpts {
  width?: number
  height?: number
  title?: string
  xlabel?: string
  ylabel?: string
}

interface Series {
  type: 'line' | 'scatter' | 'bar'
  x: number[]
  y: number[]
  color: string
  label?: string
  lineWidth: number
  markerSize: number
  barWidth: number
}



  const COLORS = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f']
  let colorIdx = 0

  const MARGIN = { top: 40, right: 20, bottom: 50, left: 60 }

  let series: Series[] = []
  let figOpts: FigureOpts = { width: 640, height: 480 }

  function nextColor(): string {
    return COLORS[colorIdx++ % COLORS.length]
  }

  function isTensorLike(value: unknown): value is TensorLike {
    return !!value && typeof value === 'object' && Array.isArray((value as any).shape) && typeof (value as any).requires_grad === 'boolean'
  }

  function values(value: unknown): unknown {
    if ((isTensorLike(value) || !!value) && typeof (value as any)?.to_array === 'function') return (value as any).to_array()
    if ((isTensorLike(value) || !!value) && typeof (value as any)?.to_array === 'function') return (value as any).to_array()
    return value
  }

  function toNumbers(data: TensorLike | number[]): number[] {
    if (Array.isArray(data)) return data as number[]
    // Flatten: if shape is [N,1] treat as 1D
    const arr = values(data)
    if (typeof arr === 'number') return [arr]
    if (Array.isArray(arr) && arr.length > 0) {
      if (typeof arr[0] === 'number') return arr as number[]
      // [N,1] column vector: flatten
      if (Array.isArray(arr[0]) && (arr[0] as number[]).length === 1) {
        return (arr as number[][]).map(r => r[0])
      }
    }
    throw new Error('plot: expected 1D data')
  }

  function linearScale(domain: [number, number], range: [number, number]) {
    const [d0, d1] = domain
    const [r0, r1] = range
    const span = d1 - d0 || 1
    return (v: number) => r0 + (v - d0) / span * (r1 - r0)
  }

  function niceRange(min: number, max: number): [number, number] {
    if (min === max) { min -= 1; max += 1 }
    const pad = (max - min) * 0.05
    return [min - pad, max + pad]
  }

  function niceStep(range: number, maxTicks: number): number {
    const rough = range / maxTicks
    const pow = Math.pow(10, Math.floor(Math.log10(rough)))
    const norm = rough / pow
    let step: number
    if (norm <= 1.5) step = 1
    else if (norm <= 3) step = 2
    else if (norm <= 7) step = 5
    else step = 10
    return step * pow
  }

  function generateTicks(min: number, max: number, maxTicks: number = 8): number[] {
    const step = niceStep(max - min, maxTicks)
    const start = Math.ceil(min / step) * step
    const ticks: number[] = []
    for (let v = start; v <= max + step * 0.01; v += step) {
      ticks.push(v)
    }
    return ticks
  }

  function formatNum(v: number): string {
    if (Math.abs(v) < 1e-10) return '0'
    if (Math.abs(v) >= 1e6 || (Math.abs(v) < 0.01 && v !== 0)) return v.toExponential(1)
    const s = v.toPrecision(4)
    // trim trailing zeros after decimal
    if (s.indexOf('.') >= 0) {
      let end = s.length
      while (end > 0 && s[end - 1] === '0') end--
      if (end > 0 && s[end - 1] === '.') end--
      return s.slice(0, end)
    }
    return s
  }

  function escXml(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
  }

  // ---- Public API ----

  function figure(opts?: FigureOpts) {
    series = []
    colorIdx = 0
    figOpts = { width: 640, height: 480, ...opts }
  }

  function title(t: string) { figOpts.title = t }
  function xlabel(l: string) { figOpts.xlabel = l }
  function ylabel(l: string) { figOpts.ylabel = l }

  function plot(yOrX: TensorLike | number[], yOrOpts?: TensorLike | number[] | PlotOpts, opts?: PlotOpts) {
    let xArr: number[], yArr: number[], o: PlotOpts = {}
    if (yOrOpts === undefined || (yOrOpts && !Array.isArray(yOrOpts) && typeof (yOrOpts as any).to_array !== 'function' && typeof yOrOpts === 'object')) {
      // plot(y) or plot(y, opts)
      yArr = toNumbers(yOrX)
      xArr = yArr.map((_: number, i: number) => i)
      o = (yOrOpts as PlotOpts) || {}
    } else {
      // plot(x, y) or plot(x, y, opts)
      xArr = toNumbers(yOrX)
      yArr = toNumbers(yOrOpts as TensorLike | number[])
      o = opts || {}
    }
    series.push({
      type: 'line', x: xArr, y: yArr,
      color: o.color || nextColor(),
      label: o.label,
      lineWidth: o.lineWidth || 2,
      markerSize: 0, barWidth: 0
    })
  }

  function scatter(x: TensorLike | number[], y: TensorLike | number[], opts?: PlotOpts) {
    const xArr = toNumbers(x), yArr = toNumbers(y)
    const o = opts || {}
    series.push({
      type: 'scatter', x: xArr, y: yArr,
      color: o.color || nextColor(),
      label: o.label,
      lineWidth: 0,
      markerSize: o.markerSize || 4, barWidth: 0
    })
  }

  function bar(x: TensorLike | number[], heights: TensorLike | number[], opts?: BarOpts) {
    const xArr = toNumbers(x), yArr = toNumbers(heights)
    const o = opts || {}
    series.push({
      type: 'bar', x: xArr, y: yArr,
      color: o.color || nextColor(),
      label: o.label,
      lineWidth: 0, markerSize: 0,
      barWidth: o.width || 0.8
    })
  }

  function render(): string {
    const W = figOpts.width || 640
    const H = figOpts.height || 480
    const plotW = W - MARGIN.left - MARGIN.right
    const plotH = H - MARGIN.top - MARGIN.bottom

    // compute data bounds
    let xMin = Infinity, xMax = -Infinity, yMin = Infinity, yMax = -Infinity
    for (const s of series) {
      for (const v of s.x) { if (v < xMin) xMin = v; if (v > xMax) xMax = v }
      for (const v of s.y) { if (v < yMin) yMin = v; if (v > yMax) yMax = v }
    }
    if (!isFinite(xMin)) { xMin = 0; xMax = 1; yMin = 0; yMax = 1 }

    // for bar charts, include y=0 baseline
    const hasBars = series.some(s => s.type === 'bar')
    if (hasBars && yMin > 0) yMin = 0

    const [xLo, xHi] = niceRange(xMin, xMax)
    const [yLo, yHi] = niceRange(yMin, yMax)

    const sx = linearScale([xLo, xHi], [0, plotW])
    const sy = linearScale([yLo, yHi], [plotH, 0]) // y flipped

    const xTicks = generateTicks(xLo, xHi)
    const yTicks = generateTicks(yLo, yHi)

    let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" `
    svg += `viewBox="0 0 ${W} ${H}" font-family="sans-serif" font-size="12">\n`
    svg += `<rect width="${W}" height="${H}" fill="white"/>\n`
    svg += `<g transform="translate(${MARGIN.left},${MARGIN.top})">\n`

    // grid lines
    svg += `<g stroke="#e0e0e0" stroke-width="0.5">\n`
    for (const t of yTicks) {
      const py = sy(t)
      svg += `<line x1="0" y1="${py.toFixed(1)}" x2="${plotW}" y2="${py.toFixed(1)}"/>\n`
    }
    for (const t of xTicks) {
      const px = sx(t)
      svg += `<line x1="${px.toFixed(1)}" y1="0" x2="${px.toFixed(1)}" y2="${plotH}"/>\n`
    }
    svg += `</g>\n`

    // axes
    svg += `<g stroke="black" stroke-width="1">\n`
    svg += `<line x1="0" y1="${plotH}" x2="${plotW}" y2="${plotH}"/>\n`
    svg += `<line x1="0" y1="0" x2="0" y2="${plotH}"/>\n`
    svg += `</g>\n`

    // x-axis ticks + labels
    svg += `<g text-anchor="middle" fill="black">\n`
    for (const t of xTicks) {
      const px = sx(t)
      svg += `<line x1="${px.toFixed(1)}" y1="${plotH}" x2="${px.toFixed(1)}" y2="${plotH + 5}" stroke="black"/>\n`
      svg += `<text x="${px.toFixed(1)}" y="${plotH + 18}">${escXml(formatNum(t))}</text>\n`
    }
    svg += `</g>\n`

    // y-axis ticks + labels
    svg += `<g text-anchor="end" fill="black">\n`
    for (const t of yTicks) {
      const py = sy(t)
      svg += `<line x1="-5" y1="${py.toFixed(1)}" x2="0" y2="${py.toFixed(1)}" stroke="black"/>\n`
      svg += `<text x="-8" y="${(py + 4).toFixed(1)}">${escXml(formatNum(t))}</text>\n`
    }
    svg += `</g>\n`

    // clip path for plot area
    svg += `<defs><clipPath id="plot-area"><rect width="${plotW}" height="${plotH}"/></clipPath></defs>\n`
    svg += `<g clip-path="url(#plot-area)">\n`

    // render series
    for (const s of series) {
      if (s.type === 'line') {
        let d = ''
        for (let i = 0; i < s.x.length; i++) {
          const px = sx(s.x[i]).toFixed(2)
          const py = sy(s.y[i]).toFixed(2)
          d += i === 0 ? `M${px},${py}` : `L${px},${py}`
        }
        svg += `<path d="${d}" fill="none" stroke="${s.color}" stroke-width="${s.lineWidth}"/>\n`
      } else if (s.type === 'scatter') {
        for (let i = 0; i < s.x.length; i++) {
          const px = sx(s.x[i]).toFixed(2)
          const py = sy(s.y[i]).toFixed(2)
          svg += `<circle cx="${px}" cy="${py}" r="${s.markerSize}" fill="${s.color}"/>\n`
        }
      } else if (s.type === 'bar') {
        const barPixelW = Math.abs(sx(s.barWidth) - sx(0)) || 20
        const yZero = sy(0)
        for (let i = 0; i < s.x.length; i++) {
          const px = sx(s.x[i]) - barPixelW / 2
          const py = sy(s.y[i])
          const h = yZero - py
          if (h >= 0) {
            svg += `<rect x="${px.toFixed(2)}" y="${py.toFixed(2)}" width="${barPixelW.toFixed(2)}" height="${h.toFixed(2)}" fill="${s.color}"/>\n`
          } else {
            svg += `<rect x="${px.toFixed(2)}" y="${yZero.toFixed(2)}" width="${barPixelW.toFixed(2)}" height="${(-h).toFixed(2)}" fill="${s.color}"/>\n`
          }
        }
      }
    }

    svg += `</g>\n` // clip group

    // title
    if (figOpts.title) {
      svg += `<text x="${plotW / 2}" y="-15" text-anchor="middle" font-size="16" font-weight="bold">${escXml(figOpts.title)}</text>\n`
    }

    // xlabel
    if (figOpts.xlabel) {
      svg += `<text x="${plotW / 2}" y="${plotH + 40}" text-anchor="middle">${escXml(figOpts.xlabel)}</text>\n`
    }

    // ylabel
    if (figOpts.ylabel) {
      svg += `<text x="-40" y="${plotH / 2}" text-anchor="middle" transform="rotate(-90,-40,${plotH / 2})">${escXml(figOpts.ylabel)}</text>\n`
    }

    // legend
    const labeled = series.filter(s => s.label)
    if (labeled.length > 0) {
      const lx = plotW - 10
      let ly = 5
      for (const s of labeled) {
        svg += `<rect x="${lx - 90}" y="${ly}" width="12" height="12" fill="${s.color}"/>\n`
        svg += `<text x="${lx - 74}" y="${ly + 10}" font-size="11">${escXml(s.label!)}</text>\n`
        ly += 18
      }
    }

    svg += `</g>\n` // main transform group
    svg += `</svg>\n`

    return svg
  }

  function show() {
    const svg = render()
    // reset for next figure
    series = []
    colorIdx = 0
    figOpts = { width: 640, height: 480 }
    // Return object with repr protocol for rich display
    return {
      repr() { return { mime: 'image/svg+xml', data: svg } },
      toString() { return svg }
    }
  }

  function savefig(path: string): void {
    const svg = render()
    fs.writeFileSync(path, svg)
    // reset for next figure
    series = []
    colorIdx = 0
    figOpts = { width: 640, height: 480 }
  }

export { figure, title, xlabel, ylabel, plot, scatter, bar, show, savefig, render }
export default { figure, title, xlabel, ylabel, plot, scatter, bar, show, savefig, render }
