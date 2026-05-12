import { useEffect, useMemo, useState } from 'react'

import { api } from './api'
import type {
  AdminOverview,
  AdminSessionItem,
  AlertRecord,
  DeviceRecord,
  SegmentChannelPayload,
  SegmentDetail,
  SessionDetail,
  UserRecord,
} from './types'

type TabKey = 'overview' | 'users' | 'devices' | 'sessions' | 'reports' | 'jobs' | 'alerts'

const playbackChannels = new Set(['ecg', 'ecg_filtered', 'ppg_ir', 'ppg_ir_filtered', 'ppg_red', 'ppg_red_filtered'])

export default function App() {
  const [tab, setTab] = useState<TabKey>('overview')
  const [overview, setOverview] = useState<AdminOverview | null>(null)
  const [users, setUsers] = useState<UserRecord[]>([])
  const [devices, setDevices] = useState<DeviceRecord[]>([])
  const [sessions, setSessions] = useState<AdminSessionItem[]>([])
  const [alerts, setAlerts] = useState<AlertRecord[]>([])
  const [selectedUserId, setSelectedUserId] = useState<string>('')
  const [selectedSessionId, setSelectedSessionId] = useState<string>('')
  const [selectedSegmentId, setSelectedSegmentId] = useState<string>('')
  const [sessionDetail, setSessionDetail] = useState<SessionDetail | null>(null)
  const [segmentDetail, setSegmentDetail] = useState<SegmentDetail | null>(null)
  const [error, setError] = useState<string>('')

  useEffect(() => {
    void loadDashboard()
  }, [])

  useEffect(() => {
    if (!selectedSessionId) {
      setSessionDetail(null)
      setSegmentDetail(null)
      return
    }
    api
      .getSessionDetail(selectedSessionId)
      .then((detail) => {
        setSessionDetail(detail)
        setSelectedSegmentId(detail.segments[0]?.id ?? '')
      })
      .catch((err: Error) => setError(err.message))
  }, [selectedSessionId])

  useEffect(() => {
    if (!selectedSessionId || !selectedSegmentId) {
      setSegmentDetail(null)
      return
    }
    api
      .getSegmentDetail(selectedSessionId, selectedSegmentId)
      .then(setSegmentDetail)
      .catch((err: Error) => setError(err.message))
  }, [selectedSessionId, selectedSegmentId])

  async function loadDashboard() {
    try {
      setError('')
      const [nextOverview, nextUsers, nextDevices, nextSessions, nextAlerts] = await Promise.all([
        api.getOverview(),
        api.getUsers(),
        api.getDevices(),
        api.getSessions(),
        api.getAlerts(),
      ])
      setOverview(nextOverview)
      setUsers(nextUsers)
      setDevices(nextDevices)
      setSessions(nextSessions)
      setAlerts(nextAlerts)
      if (!selectedUserId && nextUsers[0]) setSelectedUserId(nextUsers[0].userId)
      if (!selectedSessionId && nextSessions[0]) setSelectedSessionId(nextSessions[0].session.id)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'unknown error')
    }
  }

  const reportSessions = useMemo(() => sessions.filter((item) => item.hasReport), [sessions])
  const jobSessions = useMemo(() => sessions.filter((item) => item.latestJob), [sessions])
  const selectedUserSessions = useMemo(
    () => sessions.filter((item) => item.session.userId === selectedUserId),
    [sessions, selectedUserId],
  )

  return (
    <div className="app-shell">
      <aside className="side-nav">
        <h1>Cardio Cloud Admin</h1>
        <p>用于演示数据管理、自动分段回溯、报告查看和云端接口检查。</p>
        {([
          ['overview', '总览'],
          ['users', '用户'],
          ['devices', '设备'],
          ['sessions', '会话'],
          ['reports', '报告'],
          ['jobs', '任务'],
          ['alerts', '告警'],
        ] as Array<[TabKey, string]>).map(([key, label]) => (
          <button key={key} className={tab === key ? 'active' : ''} onClick={() => setTab(key)}>
            {label}
          </button>
        ))}
        <button onClick={() => void loadDashboard()}>刷新数据</button>
      </aside>
      <main className="content">
        {error ? <p className="error">{error}</p> : null}
        {tab === 'overview' && overview ? <OverviewPage overview={overview} /> : null}
        {tab === 'users' ? (
          <UsersPage
            users={users}
            sessions={selectedUserSessions}
            selectedUserId={selectedUserId}
            selectedSessionId={selectedSessionId}
            sessionDetail={sessionDetail}
            segmentDetail={segmentDetail}
            onSelectUser={setSelectedUserId}
            onSelectSession={setSelectedSessionId}
            onSelectSegment={setSelectedSegmentId}
          />
        ) : null}
        {tab === 'devices' ? <DevicesPage devices={devices} /> : null}
        {tab === 'sessions' ? (
          <SessionsPage
            sessions={sessions}
            sessionDetail={sessionDetail}
            segmentDetail={segmentDetail}
            onSelect={setSelectedSessionId}
            onSelectSegment={setSelectedSegmentId}
            selectedSessionId={selectedSessionId}
          />
        ) : null}
        {tab === 'reports' ? (
          <ReportsPage
            sessions={reportSessions}
            sessionDetail={sessionDetail}
            onSelect={setSelectedSessionId}
            selectedSessionId={selectedSessionId}
          />
        ) : null}
        {tab === 'jobs' ? <JobsPage sessions={jobSessions} /> : null}
        {tab === 'alerts' ? <AlertsPage alerts={alerts} /> : null}
      </main>
    </div>
  )
}

function OverviewPage({ overview }: { overview: AdminOverview }) {
  const metrics = [
    ['用户数', overview.userCount],
    ['设备数', overview.deviceCount],
    ['会话数', overview.sessionCount],
    ['分段数', overview.segmentCount],
    ['上传数', overview.uploadCount],
    ['报告数', overview.reportCount],
    ['原始块', overview.rawChunkCount],
  ]

  return (
    <>
      <div className="grid">
        {metrics.map(([label, value]) => (
          <section className="card" key={label}>
            <div>{label}</div>
            <div className="metric-value">{value}</div>
          </section>
        ))}
      </div>
      <section className="card" style={{ marginTop: 16 }}>
        <h2>最近会话</h2>
        <table className="table">
          <thead>
            <tr>
              <th>用户</th>
              <th>设备</th>
              <th>模式</th>
              <th>更新时间</th>
            </tr>
          </thead>
          <tbody>
            {overview.latestSessions.map((item) => (
              <tr key={item.id}>
                <td>{item.userName}</td>
                <td>{item.deviceId}</td>
                <td>{item.sourceMode}</td>
                <td>{item.updatedAt}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </>
  )
}

function UsersPage({
  users,
  sessions,
  selectedUserId,
  selectedSessionId,
  sessionDetail,
  segmentDetail,
  onSelectUser,
  onSelectSession,
  onSelectSegment,
}: {
  users: UserRecord[]
  sessions: AdminSessionItem[]
  selectedUserId: string
  selectedSessionId: string
  sessionDetail: SessionDetail | null
  segmentDetail: SegmentDetail | null
  onSelectUser: (id: string) => void
  onSelectSession: (id: string) => void
  onSelectSegment: (id: string) => void
}) {
  return (
    <div className="detail-grid">
      <section className="card">
        <h2>用户</h2>
        <table className="table">
          <thead>
            <tr>
              <th>姓名/编号</th>
              <th>会话</th>
            </tr>
          </thead>
          <tbody>
            {users.map((item) => (
              <tr key={item.userId} onClick={() => onSelectUser(item.userId)} style={rowStyle(selectedUserId === item.userId)}>
                <td>{item.userName}</td>
                <td>{item.sessionCount}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <section className="card">
        <h2>用户会话</h2>
        <table className="table">
          <thead>
            <tr>
              <th>设备</th>
              <th>分段</th>
              <th>更新时间</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((item) => (
              <tr key={item.session.id} onClick={() => onSelectSession(item.session.id)} style={rowStyle(selectedSessionId === item.session.id)}>
                <td>{item.session.deviceId}</td>
                <td>{item.segmentCount}</td>
                <td>{item.session.updatedAt}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <SegmentPanel detail={sessionDetail} segmentDetail={segmentDetail} onSelectSegment={onSelectSegment} />
    </div>
  )
}

function DevicesPage({ devices }: { devices: DeviceRecord[] }) {
  return (
    <section className="card">
      <h2>设备列表</h2>
      <table className="table">
        <thead>
          <tr>
            <th>设备 ID</th>
            <th>来源</th>
            <th>最近状态</th>
            <th>最近心跳</th>
          </tr>
        </thead>
        <tbody>
          {devices.map((item) => (
            <tr key={item.deviceId}>
              <td>{item.deviceId}</td>
              <td>{item.sourceMode}</td>
              <td><span className="pill">{item.lastStatus}</span></td>
              <td>{item.lastSeenAt}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function SessionsPage({
  sessions,
  sessionDetail,
  segmentDetail,
  onSelect,
  onSelectSegment,
  selectedSessionId,
}: {
  sessions: AdminSessionItem[]
  sessionDetail: SessionDetail | null
  segmentDetail: SegmentDetail | null
  onSelect: (id: string) => void
  onSelectSegment: (id: string) => void
  selectedSessionId: string
}) {
  return (
    <div className="detail-grid">
      <section className="card">
        <h2>会话列表</h2>
        <table className="table">
          <thead>
            <tr>
              <th>用户</th>
              <th>设备</th>
              <th>分段</th>
              <th>报告</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((item) => (
              <tr key={item.session.id} onClick={() => onSelect(item.session.id)} style={rowStyle(selectedSessionId === item.session.id)}>
                <td>{item.session.userName}</td>
                <td>{item.session.deviceId}</td>
                <td>{item.segmentCount}</td>
                <td>{item.hasReport ? '已生成' : '未生成'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <SegmentPanel detail={sessionDetail} segmentDetail={segmentDetail} onSelectSegment={onSelectSegment} />
    </div>
  )
}

function SegmentPanel({
  detail,
  segmentDetail,
  onSelectSegment,
}: {
  detail: SessionDetail | null
  segmentDetail: SegmentDetail | null
  onSelectSegment: (id: string) => void
}) {
  return (
    <section className="card wide-card">
      <h2>分段回溯</h2>
      {detail ? (
        <>
          <p className="notice">
            {detail.session.userName} / {detail.session.deviceId}，共 {detail.segments.length} 段
          </p>
          <div className="segment-list">
            {detail.segments.map((item) => (
              <button key={item.id} onClick={() => onSelectSegment(item.id)}>
                #{item.segmentIndex} · {item.sampleCount} 点
              </button>
            ))}
          </div>
          {segmentDetail ? <SegmentPlayback segment={segmentDetail} /> : <p className="notice">选择一个分段查看波形。</p>}
        </>
      ) : (
        <p className="notice">请选择一个会话。</p>
      )}
    </section>
  )
}

function SegmentPlayback({ segment }: { segment: SegmentDetail }) {
  const [reportSummary, setReportSummary] = useState<string>('')
  const [isAnalyzing, setIsAnalyzing] = useState(false)
  const channels = segment.channels.filter((item) => playbackChannels.has(item.channelKey))
  const csvUrl = api.getSegmentCsvUrl(segment.sessionId, segment.id)

  async function analyzeSegment() {
    setIsAnalyzing(true)
    setReportSummary('')
    try {
      const result = await api.analyzeSegment(segment.sessionId, segment.id)
      setReportSummary(result.report.summary)
    } catch (err) {
      setReportSummary(err instanceof Error ? err.message : '分析失败')
    } finally {
      setIsAnalyzing(false)
    }
  }

  return (
    <div>
      <p>
        当前分段 #{segment.segmentIndex}，时间 {segment.startTimestampMs} - {segment.endTimestampMs}，通道 {channels.length} 个。
      </p>
      <div className="segment-actions">
        <a href={csvUrl} target="_blank" rel="noreferrer">下载 CSV</a>
        <button onClick={() => void analyzeSegment()} disabled={isAnalyzing}>
          {isAnalyzing ? '分析中...' : '调用大模型/规则分析'}
        </button>
      </div>
      {reportSummary ? <p className="notice">{reportSummary}</p> : null}
      {channels.map((channel) => (
        <div key={channel.channelKey} className="waveform-preview">
          <div className="waveform-title">
            <strong>{channel.channelKey}</strong>
            <span>{channel.samples.length} 点 · {channel.sampleRate} Hz · 质量 {(channel.quality * 100).toFixed(0)}%</span>
          </div>
          <MiniWaveform channel={channel} />
        </div>
      ))}
    </div>
  )
}

function MiniWaveform({ channel }: { channel: SegmentChannelPayload }) {
  const width = 680
  const height = 140
  const samples = downsample(channel.samples, 240)
  const min = Math.min(...samples)
  const max = Math.max(...samples)
  const range = Math.max(0.000001, max - min)
  const points = samples
    .map((value, index) => {
      const x = samples.length <= 1 ? 0 : (index / (samples.length - 1)) * width
      const y = height - ((value - min) / range) * height
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    .join(' ')
  return (
    <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${channel.channelKey} waveform`}>
      <polyline points={points} fill="none" stroke="#0b6e4f" strokeWidth="2" />
    </svg>
  )
}

function ReportsPage({ sessions, sessionDetail, onSelect, selectedSessionId }: { sessions: AdminSessionItem[]; sessionDetail: SessionDetail | null; onSelect: (id: string) => void; selectedSessionId: string }) {
  return (
    <div className="detail-grid">
      <section className="card">
        <h2>报告会话</h2>
        <table className="table">
          <thead>
            <tr>
              <th>用户</th>
              <th>设备</th>
            </tr>
          </thead>
          <tbody>
            {sessions.map((item) => (
              <tr key={item.session.id} onClick={() => onSelect(item.session.id)} style={rowStyle(selectedSessionId === item.session.id)}>
                <td>{item.session.userName}</td>
                <td>{item.session.deviceId}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      <section className="card">
        <h2>报告内容</h2>
        {sessionDetail?.report ? (
          <>
            <p>{sessionDetail.report.summary}</p>
            <p>置信度: {sessionDetail.report.confidence ?? '未提供'}</p>
            <h3>建议</h3>
            <ul>
              {sessionDetail.report.recommendations.map((item) => <li key={item}>{item}</li>)}
            </ul>
          </>
        ) : (
          <p className="notice">当前会话暂无报告，或尚未选择会话。</p>
        )}
      </section>
    </div>
  )
}

function JobsPage({ sessions }: { sessions: AdminSessionItem[] }) {
  return (
    <section className="card">
      <h2>分析任务</h2>
      <table className="table">
        <thead>
          <tr>
            <th>会话</th>
            <th>状态</th>
            <th>摘要</th>
          </tr>
        </thead>
        <tbody>
          {sessions.map((item) => (
            <tr key={item.session.id}>
              <td>{item.session.id}</td>
              <td>{item.latestJob?.status ?? '-'}</td>
              <td>{item.latestJob?.summary ?? '-'}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function AlertsPage({ alerts }: { alerts: AlertRecord[] }) {
  return (
    <section className="card">
      <h2>告警列表</h2>
      <table className="table">
        <thead>
          <tr>
            <th>时间</th>
            <th>设备</th>
            <th>级别</th>
            <th>内容</th>
          </tr>
        </thead>
        <tbody>
          {alerts.map((item) => (
            <tr key={item.id}>
              <td>{item.createdAt}</td>
              <td>{item.deviceId}</td>
              <td>{item.severity}</td>
              <td>{item.message}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function rowStyle(active: boolean) {
  return {
    cursor: 'pointer',
    background: active ? '#f6fbf8' : undefined,
  }
}

function downsample(samples: number[], maxPoints: number) {
  if (samples.length <= maxPoints) return samples
  const bucketSize = Math.ceil(samples.length / maxPoints)
  const result: number[] = []
  for (let start = 0; start < samples.length; start += bucketSize) {
    const end = Math.min(samples.length, start + bucketSize)
    let min = samples[start]
    let max = samples[start]
    for (let index = start + 1; index < end; index += 1) {
      min = Math.min(min, samples[index])
      max = Math.max(max, samples[index])
    }
    result.push(min, max)
  }
  return result
}
