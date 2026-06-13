import React, { useMemo, useState } from 'react'
import { createRoot } from 'react-dom/client'
import './styles.css'

type Params = {
  ecgHighpassHz: number
  ecgLowpassHz: number
  ecgNotchEnabled: boolean
  ecgNotchHz: number
  ecgNotchQ: number
  ppgHighpassHz: number
  ppgLowpassHz: number
  nlmsTaps: number
  nlmsStep: number
  nlmsEpsilon: number
  motionThreshold: number
}

type Row = {
  t: number
  ecg: number
  ppgIr: number
  ppgRed: number
  ax: number
  ay: number
  az: number
}

const defaultParams: Params = {
  ecgHighpassHz: 0.5,
  ecgLowpassHz: 38,
  ecgNotchEnabled: true,
  ecgNotchHz: 50,
  ecgNotchQ: 30,
  ppgHighpassHz: 0.35,
  ppgLowpassHz: 7,
  nlmsTaps: 8,
  nlmsStep: 0.02,
  nlmsEpsilon: 0.001,
  motionThreshold: 650,
}

function App() {
  const [rows, setRows] = useState<Row[]>(demoRows())
  const [params, setParams] = useState<Params>(defaultParams)
  const [viewSeconds, setViewSeconds] = useState(12)
  const [viewStartRatio, setViewStartRatio] = useState(0)
  const result = useMemo(() => runDsp(rows, params), [rows, params])
  const viewRange = useMemo(
    () => buildViewRange(rows, viewSeconds, viewStartRatio),
    [rows, viewSeconds, viewStartRatio],
  )
  const exportedJson = JSON.stringify({ type: 'set_dsp_params', payload: params }, null, 2)
  const exportedCpp = toCpp(params)

  async function loadCsv(file: File) {
    const text = await file.text()
    setRows(parseCsv(text))
    setViewStartRatio(0)
  }

  return (
    <div className="app">
      <header>
        <div>
          <p className="eyebrow">Cardio DSP Lab</p>
          <h1>Edge DSP tuning workspace</h1>
        </div>
        <label className="file-button">
          Import CSV
          <input type="file" accept=".csv,text/csv" onChange={(event) => {
            const file = event.target.files?.[0]
            if (file) void loadCsv(file)
          }} />
        </label>
      </header>

      <main>
        <section className="panel controls">
          <h2>Parameters</h2>
          <Slider label="ECG highpass Hz" value={params.ecgHighpassHz} min={0.1} max={2} step={0.1} onChange={(v) => setParams({ ...params, ecgHighpassHz: v })} />
          <Slider label="ECG lowpass Hz" value={params.ecgLowpassHz} min={20} max={50} step={1} onChange={(v) => setParams({ ...params, ecgLowpassHz: v })} />
          <Slider label="Notch Q" value={params.ecgNotchQ} min={10} max={45} step={1} onChange={(v) => setParams({ ...params, ecgNotchQ: v })} />
          <label className="toggle"><input type="checkbox" checked={params.ecgNotchEnabled} onChange={(e) => setParams({ ...params, ecgNotchEnabled: e.target.checked })} /> Enable 50Hz notch</label>
          <Slider label="PPG highpass Hz" value={params.ppgHighpassHz} min={0.1} max={1.5} step={0.05} onChange={(v) => setParams({ ...params, ppgHighpassHz: v })} />
          <Slider label="PPG lowpass Hz" value={params.ppgLowpassHz} min={3} max={12} step={0.5} onChange={(v) => setParams({ ...params, ppgLowpassHz: v })} />
          <Slider label="NLMS taps" value={params.nlmsTaps} min={1} max={16} step={1} onChange={(v) => setParams({ ...params, nlmsTaps: Math.round(v) })} />
          <Slider label="NLMS step" value={params.nlmsStep} min={0.001} max={0.08} step={0.001} onChange={(v) => setParams({ ...params, nlmsStep: v })} />
          <Slider label="Motion threshold" value={params.motionThreshold} min={50} max={2500} step={10} onChange={(v) => setParams({ ...params, motionThreshold: v })} />
        </section>

        <section className="panel charts">
          <MetricStrip rows={rows} result={result} />
          <ViewControls
            rows={rows}
            range={viewRange}
            viewSeconds={viewSeconds}
            viewStartRatio={viewStartRatio}
            onViewSecondsChange={setViewSeconds}
            onViewStartRatioChange={setViewStartRatio}
          />
          <WaveChart title="ECG raw vs filtered" raw={rows.map((r) => r.ecg)} filtered={result.ecgFiltered} color="#d84b5f" range={viewRange} />
          <WaveChart title="PPG IR raw vs filtered" raw={rows.map((r) => r.ppgIr)} filtered={result.ppgIrFiltered} color="#247ba0" range={viewRange} />
          <WaveChart title="PPG RED raw vs filtered" raw={rows.map((r) => r.ppgRed)} filtered={result.ppgRedFiltered} color="#a94b5d" range={viewRange} />
          <WaveChart title="Motion reference" raw={result.motion} filtered={result.motion.map(() => params.motionThreshold)} color="#6d5dfc" range={viewRange} sharedScale />
        </section>

        <section className="panel export">
          <h2>Export</h2>
          <p>Copy JSON into MQTT/BLE control, or paste the C++ block into firmware defaults after tuning.</p>
          <textarea readOnly value={exportedJson} />
          <textarea readOnly value={exportedCpp} />
        </section>
      </main>
    </div>
  )
}

function Slider(props: { label: string; value: number; min: number; max: number; step: number; onChange: (value: number) => void }) {
  return (
    <label className="slider">
      <span>{props.label}<b>{props.value.toFixed(props.step < 0.01 ? 3 : props.step < 0.1 ? 2 : 1)}</b></span>
      <input type="range" min={props.min} max={props.max} step={props.step} value={props.value} onChange={(e) => props.onChange(Number(e.target.value))} />
    </label>
  )
}

function MetricStrip({ rows, result }: { rows: Row[]; result: ReturnType<typeof runDsp> }) {
  const durationSeconds = rows.length > 1
    ? Math.max(0, (rows[rows.length - 1].t - rows[0].t) / 1000)
    : 0
  return (
    <div className="metrics">
      <div><span>Samples</span><b>{rows.length}</b></div>
      <div><span>Duration</span><b>{durationSeconds.toFixed(1)}s</b></div>
      <div><span>Motion max</span><b>{Math.max(...result.motion).toFixed(0)}</b></div>
      <div><span>ECG quality</span><b>{(result.ecgQuality * 100).toFixed(0)}%</b></div>
      <div><span>PPG quality</span><b>{(result.ppgQuality * 100).toFixed(0)}%</b></div>
    </div>
  )
}

type ViewRange = {
  startIndex: number
  endIndex: number
  startMs: number
  endMs: number
  durationMs: number
}

function ViewControls(props: {
  rows: Row[]
  range: ViewRange
  viewSeconds: number
  viewStartRatio: number
  onViewSecondsChange: (value: number) => void
  onViewStartRatioChange: (value: number) => void
}) {
  const totalDurationSeconds = props.rows.length > 1
    ? Math.max(0, (props.rows[props.rows.length - 1].t - props.rows[0].t) / 1000)
    : 0
  const baseMs = props.rows[0]?.t ?? 0
  const canScroll = totalDurationSeconds > props.viewSeconds
  const visibleSamples = Math.max(0, props.range.endIndex - props.range.startIndex)
  return (
    <div className="view-panel">
      <div className="view-row">
        <label>
          <span>View window</span>
          <b>{props.viewSeconds.toFixed(0)}s</b>
          <input
            type="range"
            min={2}
            max={Math.max(6, Math.min(120, Math.ceil(totalDurationSeconds || 60)))}
            step={1}
            value={props.viewSeconds}
            onChange={(event) => props.onViewSecondsChange(Number(event.target.value))}
          />
        </label>
        <label>
          <span>Position</span>
          <b>{formatSeconds(props.range.startMs - baseMs)} - {formatSeconds(props.range.endMs - baseMs)}</b>
          <input
            type="range"
            min={0}
            max={1}
            step={0.001}
            value={props.viewStartRatio}
            disabled={!canScroll}
            onChange={(event) => props.onViewStartRatioChange(Number(event.target.value))}
          />
        </label>
      </div>
      <div className="view-actions">
        <button type="button" onClick={() => props.onViewStartRatioChange(0)}>Start</button>
        <button type="button" onClick={() => props.onViewStartRatioChange(Math.max(0, props.viewStartRatio - 0.1))}>Prev</button>
        <button type="button" onClick={() => props.onViewStartRatioChange(Math.min(1, props.viewStartRatio + 0.1))}>Next</button>
        <button type="button" onClick={() => props.onViewStartRatioChange(1)}>End</button>
        <span>{visibleSamples} visible samples, {totalDurationSeconds.toFixed(1)}s total</span>
      </div>
    </div>
  )
}

function WaveChart({
  title,
  raw,
  filtered,
  color,
  range,
  sharedScale = false,
}: {
  title: string
  raw: number[]
  filtered: number[]
  color: string
  range: ViewRange
  sharedScale?: boolean
}) {
  const width = 920
  const height = 180
  const sharedScaleValues = sharedScale ? [...raw, ...filtered] : undefined
  const rawPath = toPath(raw, width, height, range, sharedScaleValues)
  const filteredPath = toPath(filtered, width, height, range, sharedScaleValues)
  const visibleCount = Math.max(0, range.endIndex - range.startIndex)
  return (
    <div className="chart">
      <h3><span>{title}</span><small>{visibleCount} samples</small></h3>
      <svg viewBox={`0 0 ${width} ${height}`} role="img">
        <line x1="0" x2={width} y1={height / 2} y2={height / 2} stroke="#e4ebe6" strokeWidth="1" />
        <path d={rawPath} fill="none" stroke="#aeb9b3" strokeWidth="1.4" />
        <path d={filteredPath} fill="none" stroke={color} strokeWidth="2" />
      </svg>
    </div>
  )
}

function toPath(values: number[], width: number, height: number, range: ViewRange, scaleReference?: number[]) {
  if (values.length === 0) return ''
  const start = Math.max(0, Math.min(values.length, range.startIndex))
  const end = Math.max(start, Math.min(values.length, range.endIndex))
  if (end <= start) return ''
  const sampled = downsampleForPixels(values, start, end, width)
  const scaleValues = scaleReference
    ? [
        ...values.slice(start, end),
        ...scaleReference.slice(start, Math.min(scaleReference.length, end)),
      ]
    : values.slice(start, end)
  const min = Math.min(...scaleValues)
  const max = Math.max(...scaleValues)
  const valueRange = Math.max(1, max - min)
  return sampled.map((point, index) => {
    const y = height - ((point.value - min) / valueRange) * (height - 14) - 7
    const x = point.x
    return `${index === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

function downsampleForPixels(values: number[], start: number, end: number, width: number) {
  const length = end - start
  if (length <= 0) return []
  if (length <= width * 1.5) {
    return values.slice(start, end).map((value, offset) => ({
      x: (offset / Math.max(1, length - 1)) * width,
      value,
    }))
  }
  const bucketCount = Math.max(1, Math.floor(width))
  const bucketSize = length / bucketCount
  const out: Array<{ x: number; value: number }> = []
  for (let bucket = 0; bucket < bucketCount; bucket += 1) {
    const bucketStart = start + Math.floor(bucket * bucketSize)
    const bucketEnd = Math.min(end, start + Math.floor((bucket + 1) * bucketSize))
    if (bucketStart >= bucketEnd) continue
    let min = values[bucketStart]
    let max = values[bucketStart]
    let minIndex = bucketStart
    let maxIndex = bucketStart
    for (let j = bucketStart + 1; j < bucketEnd; j += 1) {
      min = Math.min(min, values[j])
      max = Math.max(max, values[j])
      if (values[j] === min) minIndex = j
      if (values[j] === max) maxIndex = j
    }
    const points = minIndex <= maxIndex
      ? [
          { index: minIndex, value: min },
          { index: maxIndex, value: max },
        ]
      : [
          { index: maxIndex, value: max },
          { index: minIndex, value: min },
        ]
    for (const point of points) {
      out.push({
        x: ((point.index - start) / Math.max(1, length - 1)) * width,
        value: point.value,
      })
    }
  }
  return out
}

function buildViewRange(rows: Row[], viewSeconds: number, viewStartRatio: number): ViewRange {
  if (rows.length === 0) {
    return { startIndex: 0, endIndex: 0, startMs: 0, endMs: 0, durationMs: 0 }
  }
  const firstMs = rows[0].t
  const lastMs = rows[rows.length - 1].t
  const totalMs = Math.max(0, lastMs - firstMs)
  const windowMs = Math.min(Math.max(1, viewSeconds * 1000), Math.max(1, totalMs))
  const maxStartMs = Math.max(firstMs, lastMs - windowMs)
  const startMs = firstMs + (maxStartMs - firstMs) * Math.min(1, Math.max(0, viewStartRatio))
  const endMs = Math.min(lastMs, startMs + windowMs)
  const startIndex = lowerBoundRows(rows, startMs)
  const endIndex = Math.max(startIndex + 1, upperBoundRows(rows, endMs))
  return {
    startIndex,
    endIndex: Math.min(rows.length, endIndex),
    startMs,
    endMs,
    durationMs: endMs - startMs,
  }
}

function lowerBoundRows(rows: Row[], timestampMs: number) {
  let low = 0
  let high = rows.length
  while (low < high) {
    const mid = low + ((high - low) >> 1)
    if (rows[mid].t < timestampMs) low = mid + 1
    else high = mid
  }
  return low
}

function upperBoundRows(rows: Row[], timestampMs: number) {
  let low = 0
  let high = rows.length
  while (low < high) {
    const mid = low + ((high - low) >> 1)
    if (rows[mid].t <= timestampMs) low = mid + 1
    else high = mid
  }
  return low
}

function formatSeconds(timestampMs: number) {
  return `${(timestampMs / 1000).toFixed(1)}s`
}

function parseCsv(text: string): Row[] {
  const lines = text.trim().split(/\r?\n/)
  const headers = lines.shift()?.split(',').map(normalizeHeader) ?? []
  const t = pickColumn(headers, ['timestamp_ms', 'time_ms', 'timestamp', 'time'])
  const ecg = pickColumn(headers, ['ecg_filtered', 'ecg'])
  const ir = pickColumn(headers, ['ppg_ir_filtered', 'ppg_ir', 'ir_filtered', 'ir', 'ppg'])
  const red = pickColumn(headers, ['ppg_red_filtered', 'ppg_red', 'red_filtered', 'red'])
  const ax = pickColumn(headers, ['imu_ax', 'acc_x', 'ax'])
  const ay = pickColumn(headers, ['imu_ay', 'acc_y', 'ay'])
  const az = pickColumn(headers, ['imu_az', 'acc_z', 'az'])
  let lastEcg = 0
  let lastIr = 0
  let lastRed = 0
  let lastAx = 0
  let lastAy = 0
  let lastAz = 0
  return lines.map((line, index) => {
    const cells = line.split(',')
    const nextEcg = readCell(cells, ecg, lastEcg)
    const nextIr = readCell(cells, ir, lastIr)
    const nextRed = readCell(cells, red, Number.isFinite(nextIr) ? nextIr : lastRed)
    const nextAx = readCell(cells, ax, lastAx)
    const nextAy = readCell(cells, ay, lastAy)
    const nextAz = readCell(cells, az, lastAz)
    lastEcg = nextEcg
    lastIr = nextIr
    lastRed = nextRed
    lastAx = nextAx
    lastAy = nextAy
    lastAz = nextAz
    return {
      t: readCell(cells, t, index * 5),
      ecg: nextEcg,
      ppgIr: nextIr,
      ppgRed: nextRed,
      ax: nextAx,
      ay: nextAy,
      az: nextAz,
    }
  }).filter((row) => Number.isFinite(row.ecg) || Number.isFinite(row.ppgIr))
}

function normalizeHeader(header: string) {
  return header.trim().toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '')
}

function pickColumn(headers: string[], preferred: string[]) {
  for (const name of preferred) {
    const exact = headers.indexOf(name)
    if (exact >= 0) return exact
  }
  for (const name of preferred) {
    const partial = headers.findIndex((header) => header.includes(name))
    if (partial >= 0) return partial
  }
  return -1
}

function readCell(cells: string[], index: number, fallback: number) {
  if (index < 0 || index >= cells.length) return fallback
  const raw = cells[index].trim()
  if (!raw) return fallback
  const value = Number(raw)
  return Number.isFinite(value) ? value : fallback
}

function runDsp(rows: Row[], params: Params) {
  const ecgHp = highpass(params.ecgHighpassHz, 500)
  const ecgLp = lowpass(params.ecgLowpassHz, 500)
  const ppgIrHp = highpass(params.ppgHighpassHz, 200)
  const ppgIrLp = lowpass(params.ppgLowpassHz, 200)
  const ppgRedHp = highpass(params.ppgHighpassHz, 200)
  const ppgRedLp = lowpass(params.ppgLowpassHz, 200)
  const motionHp = highpass(0.25, 200)
  const motionLp = lowpass(1, 200)
  const irNlms = nlms(params.nlmsTaps)
  const redNlms = nlms(params.nlmsTaps)
  const ecgFiltered: number[] = []
  const ppgIrFiltered: number[] = []
  const ppgRedFiltered: number[] = []
  const motion: number[] = []

  rows.forEach((row) => {
    const mag = Math.sqrt(row.ax * row.ax + row.ay * row.ay + row.az * row.az)
    const m = Math.abs(motionLp(motionHp(mag)))
    motion.push(m)
    const ecg = ecgLp(ecgHp(row.ecg))
    const ir = ppgIrLp(ppgIrHp(row.ppgIr))
    const red = ppgRedLp(ppgRedHp(row.ppgRed))
    const ref = m / Math.max(1, params.motionThreshold)
    ecgFiltered.push(ecg)
    ppgIrFiltered.push(irNlms(ref, ir, params.nlmsStep, params.nlmsEpsilon))
    ppgRedFiltered.push(redNlms(ref, red, params.nlmsStep, params.nlmsEpsilon))
  })

  const motionMax = Math.max(1, ...motion)
  const quality = Math.max(0.25, Math.min(1, 1 - Math.max(0, motionMax - params.motionThreshold) / Math.max(1, params.motionThreshold) * 0.55))
  return { ecgFiltered, ppgIrFiltered, ppgRedFiltered, motion, ecgQuality: quality, ppgQuality: quality }
}

function lowpass(cutoff: number, sampleRate: number) {
  const dt = 1 / sampleRate
  const rc = 1 / (2 * Math.PI * cutoff)
  const alpha = dt / (rc + dt)
  let y = 0
  let ready = false
  return (x: number) => {
    if (!ready) {
      y = x
      ready = true
    } else {
      y += alpha * (x - y)
    }
    return y
  }
}

function highpass(cutoff: number, sampleRate: number) {
  const dt = 1 / sampleRate
  const rc = 1 / (2 * Math.PI * cutoff)
  const alpha = rc / (rc + dt)
  let prevX = 0
  let prevY = 0
  return (x: number) => {
    const y = alpha * (prevY + x - prevX)
    prevX = x
    prevY = y
    return y
  }
}

function nlms(taps: number) {
  const w = Array.from({ length: taps }, () => 0)
  const x = Array.from({ length: taps }, () => 0)
  return (reference: number, desired: number, step: number, epsilon: number) => {
    x.pop()
    x.unshift(reference)
    const estimate = w.reduce((sum, wi, i) => sum + wi * x[i], 0)
    const norm = x.reduce((sum, xi) => sum + xi * xi, epsilon)
    const error = desired - estimate
    w.forEach((_, i) => { w[i] += (step / norm) * error * x[i] })
    return error
  }
}

function toCpp(params: Params) {
  return `signal_dsp::DspParams params;
params.ecgHighpassHz = ${params.ecgHighpassHz.toFixed(3)}f;
params.ecgLowpassHz = ${params.ecgLowpassHz.toFixed(3)}f;
params.ecgNotchEnabled = ${params.ecgNotchEnabled ? 'true' : 'false'};
params.ecgNotchQ = ${params.ecgNotchQ.toFixed(3)}f;
params.ppgHighpassHz = ${params.ppgHighpassHz.toFixed(3)}f;
params.ppgLowpassHz = ${params.ppgLowpassHz.toFixed(3)}f;
params.nlmsTaps = ${Math.round(params.nlmsTaps)};
params.nlmsStep = ${params.nlmsStep.toFixed(4)}f;
params.nlmsEpsilon = ${params.nlmsEpsilon.toFixed(5)}f;
params.motionThreshold = ${params.motionThreshold.toFixed(1)}f;`
}

function demoRows(): Row[] {
  return Array.from({ length: 1600 }, (_, i) => {
    const t = i * 5
    const motionBurst = i > 520 && i < 850 ? Math.sin(i * 0.21) * 450 : 0
    const ecg = 2048 + Math.sin(i * 0.08) * 40 + (i % 100 < 6 ? 700 : 0) + motionBurst * 0.08
    const ppg = 52000 + Math.sin(i * 0.045) * 12000 + motionBurst * 18
    return {
      t,
      ecg,
      ppgIr: ppg,
      ppgRed: ppg * 0.82,
      ax: motionBurst,
      ay: Math.sin(i * 0.13) * 80,
      az: 16384 + Math.cos(i * 0.11) * 70,
    }
  })
}

createRoot(document.getElementById('root')!).render(<App />)
