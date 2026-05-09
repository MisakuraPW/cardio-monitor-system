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
  const result = useMemo(() => runDsp(rows, params), [rows, params])
  const exportedJson = JSON.stringify({ type: 'set_dsp_params', payload: params }, null, 2)
  const exportedCpp = toCpp(params)

  async function loadCsv(file: File) {
    const text = await file.text()
    setRows(parseCsv(text))
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
          <WaveChart title="ECG raw vs filtered" raw={rows.map((r) => r.ecg)} filtered={result.ecgFiltered} color="#d84b5f" />
          <WaveChart title="PPG IR raw vs filtered" raw={rows.map((r) => r.ppgIr)} filtered={result.ppgIrFiltered} color="#247ba0" />
          <WaveChart title="PPG RED raw vs filtered" raw={rows.map((r) => r.ppgRed)} filtered={result.ppgRedFiltered} color="#a94b5d" />
          <WaveChart title="Motion reference" raw={result.motion} filtered={result.motion.map(() => params.motionThreshold)} color="#6d5dfc" />
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
  return (
    <div className="metrics">
      <div><span>Samples</span><b>{rows.length}</b></div>
      <div><span>Motion max</span><b>{Math.max(...result.motion).toFixed(0)}</b></div>
      <div><span>ECG quality</span><b>{(result.ecgQuality * 100).toFixed(0)}%</b></div>
      <div><span>PPG quality</span><b>{(result.ppgQuality * 100).toFixed(0)}%</b></div>
    </div>
  )
}

function WaveChart({ title, raw, filtered, color }: { title: string; raw: number[]; filtered: number[]; color: string }) {
  const width = 920
  const height = 180
  const rawPath = toPath(raw, width, height)
  const filteredPath = toPath(filtered, width, height)
  return (
    <div className="chart">
      <h3>{title}</h3>
      <svg viewBox={`0 0 ${width} ${height}`} role="img">
        <path d={rawPath} fill="none" stroke="#aeb9b3" strokeWidth="1.4" />
        <path d={filteredPath} fill="none" stroke={color} strokeWidth="2" />
      </svg>
    </div>
  )
}

function toPath(values: number[], width: number, height: number) {
  if (values.length === 0) return ''
  const sampled = downsample(values, 800)
  const min = Math.min(...sampled)
  const max = Math.max(...sampled)
  const range = Math.max(1, max - min)
  return sampled.map((value, index) => {
    const x = (index / Math.max(1, sampled.length - 1)) * width
    const y = height - ((value - min) / range) * (height - 14) - 7
    return `${index === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
  }).join(' ')
}

function downsample(values: number[], maxPoints: number) {
  if (values.length <= maxPoints) return values
  const step = Math.ceil(values.length / maxPoints)
  const out: number[] = []
  for (let i = 0; i < values.length; i += step) {
    let min = values[i]
    let max = values[i]
    for (let j = i + 1; j < Math.min(values.length, i + step); j += 1) {
      min = Math.min(min, values[j])
      max = Math.max(max, values[j])
    }
    out.push(min, max)
  }
  return out
}

function parseCsv(text: string): Row[] {
  const lines = text.trim().split(/\r?\n/)
  const headers = lines.shift()?.split(',').map((h) => h.trim().toLowerCase()) ?? []
  const find = (...names: string[]) => headers.findIndex((h) => names.some((n) => h.includes(n)))
  const t = find('timestamp', 'time')
  const ecg = find('ecg')
  const ir = find('ir', 'ppg')
  const red = find('red')
  const ax = find('ax', 'acc_x')
  const ay = find('ay', 'acc_y')
  const az = find('az', 'acc_z')
  return lines.map((line, index) => {
    const cells = line.split(',').map(Number)
    return {
      t: cells[t] || index * 5,
      ecg: cells[ecg] || 0,
      ppgIr: cells[ir] || 0,
      ppgRed: cells[red] || cells[ir] || 0,
      ax: cells[ax] || 0,
      ay: cells[ay] || 0,
      az: cells[az] || 0,
    }
  }).filter((row) => Number.isFinite(row.ecg) || Number.isFinite(row.ppgIr))
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
