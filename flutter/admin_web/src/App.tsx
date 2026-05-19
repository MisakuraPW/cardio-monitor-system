import { useEffect, useMemo, useState } from 'react'

import { api } from './api'
import type {
  AdminOverview,
  AdminSessionItem,
  AlertRecord,
  DeviceRecord,
  LlmConfig,
  MedicalReport,
  SegmentChannelPayload,
  SegmentDetail,
  SessionDetail,
  UserRecord,
} from './types'

type TabKey = 'overview' | 'users' | 'devices' | 'sessions' | 'reports' | 'jobs' | 'alerts' | 'llm'

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
          ['llm', '大模型'],
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
        {tab === 'llm' ? <LlmPage /> : null}
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

function LlmPage() {
  const [config, setConfig] = useState<LlmConfig | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState('')
  const [activeTab, setActiveTab] = useState<'prompt' | 'schema' | 'report'>('prompt')

  const [testUrl, setTestUrl] = useState('')
  const [testKey, setTestKey] = useState('')
  const [testModel, setTestModel] = useState('')
  const [testing, setTesting] = useState(false)
  const [testResult, setTestResult] = useState<{ success: boolean; text: string } | null>(null)

  useEffect(() => {
    api
      .getLlmConfig()
      .then((cfg) => {
        setConfig(cfg)
        setTestUrl(cfg.apiBaseUrl)
        setTestModel(cfg.model)
      })
      .catch((err: Error) => setLoadError(err.message))
      .finally(() => setLoading(false))
  }, [])

  async function handleTest() {
    if (!testUrl || !testKey || !testModel) {
      setTestResult({ success: false, text: '请填写 API Base URL、API Key 和模型名。' })
      return
    }
    setTesting(true)
    setTestResult(null)
    try {
      const result = await api.testLlmConnection({ apiBaseUrl: testUrl, apiKey: testKey, model: testModel })
      if (result.success) {
        setTestResult({ success: true, text: `连接成功\n模型：${result.model ?? ''}\n响应：${result.response ?? ''}` })
      } else {
        setTestResult({ success: false, text: `连接失败\n${result.error ?? ''}` })
      }
    } catch (err) {
      setTestResult({ success: false, text: `请求异常：${err instanceof Error ? err.message : String(err)}` })
    } finally {
      setTesting(false)
    }
  }

  if (loading) return <p className="notice">加载中...</p>
  if (loadError) return <p className="error">{loadError}</p>
  if (!config) return null

  const statusColor = config.configured ? '#2a9d8f' : '#e76f51'
  const statusText = config.configured ? '已配置' : '未配置'

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* 配置状态 */}
      <section className="card">
        <h2>大模型配置状态</h2>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
          <span style={{
            display: 'inline-block', padding: '3px 14px', borderRadius: 20,
            fontSize: 13, fontWeight: 600,
            background: `${statusColor}22`, color: statusColor, border: `1px solid ${statusColor}`,
          }}>{statusText}</span>
          <span style={{ fontSize: 13, color: '#627d98' }}>通过环境变量配置，修改后需重启服务</span>
        </div>
        <table className="table" style={{ fontSize: 14 }}>
          <tbody>
            <tr><td style={{ color: '#627d98', width: 140 }}>API Base URL</td>
              <td>{config.apiBaseUrl || <em style={{ color: '#9aa5b4' }}>未设置 CARDIO_LLM_API_BASE_URL</em>}</td></tr>
            <tr><td style={{ color: '#627d98' }}>模型</td>
              <td>{config.model || <em style={{ color: '#9aa5b4' }}>未设置 CARDIO_LLM_MODEL</em>}</td></tr>
            <tr><td style={{ color: '#627d98' }}>API Key</td>
              <td>{config.configured ? '已设置（已隐藏）' : <em style={{ color: '#9aa5b4' }}>未设置 CARDIO_LLM_API_KEY</em>}</td></tr>
            <tr><td style={{ color: '#627d98' }}>Prompt 版本</td>
              <td>{config.promptVersion}</td></tr>
          </tbody>
        </table>
        <div style={{ marginTop: 12, fontSize: 12, color: '#9aa5b4', background: '#f8fafc', borderRadius: 8, padding: '10px 14px', lineHeight: 1.8 }}>
          在服务器 <code>.env</code> 中设置：<br />
          <code>CARDIO_LLM_API_BASE_URL=https://api.deepseek.com/v1</code><br />
          <code>CARDIO_LLM_API_KEY=sk-...</code><br />
          <code>CARDIO_LLM_MODEL=deepseek-chat</code>
        </div>
      </section>

      {/* 连接测试 */}
      <section className="card">
        <h2>连接测试</h2>
        <p style={{ fontSize: 13, color: '#627d98', marginBottom: 14 }}>临时填入参数测试连通性，不会修改服务器配置。</p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div>
            <label style={{ fontSize: 13, fontWeight: 500, color: '#486581', display: 'block', marginBottom: 4 }}>API Base URL</label>
            <input
              style={{ width: '100%', padding: '8px 12px', border: '1px solid #bcccdc', borderRadius: 8, fontSize: 14, outline: 'none' }}
              value={testUrl} onChange={(e) => setTestUrl(e.target.value)}
              placeholder="https://api.deepseek.com/v1"
            />
          </div>
          <div style={{ display: 'flex', gap: 12 }}>
            <div style={{ flex: 1 }}>
              <label style={{ fontSize: 13, fontWeight: 500, color: '#486581', display: 'block', marginBottom: 4 }}>API Key</label>
              <input
                style={{ width: '100%', padding: '8px 12px', border: '1px solid #bcccdc', borderRadius: 8, fontSize: 14, outline: 'none' }}
                type="password" value={testKey} onChange={(e) => setTestKey(e.target.value)}
                placeholder="sk-..."
              />
            </div>
            <div style={{ flex: 1 }}>
              <label style={{ fontSize: 13, fontWeight: 500, color: '#486581', display: 'block', marginBottom: 4 }}>模型名</label>
              <input
                style={{ width: '100%', padding: '8px 12px', border: '1px solid #bcccdc', borderRadius: 8, fontSize: 14, outline: 'none' }}
                value={testModel} onChange={(e) => setTestModel(e.target.value)}
                placeholder="deepseek-chat"
              />
            </div>
          </div>
          <div>
            <button
              onClick={() => void handleTest()}
              disabled={testing}
              style={{ padding: '9px 22px', background: '#0b6e4f', color: '#fff', border: 'none', borderRadius: 8, fontSize: 14, fontWeight: 600, cursor: testing ? 'wait' : 'pointer', opacity: testing ? 0.7 : 1 }}
            >
              {testing ? '测试中...' : '测试连接'}
            </button>
          </div>
          {testResult && (
            <div style={{
              padding: '10px 14px', borderRadius: 8, fontSize: 13, whiteSpace: 'pre-wrap', wordBreak: 'break-all',
              background: testResult.success ? '#e6f4f1' : '#fdecea',
              color: testResult.success ? '#0b6e4f' : '#c0392b',
              border: `1px solid ${testResult.success ? '#a8d5c9' : '#f5c6c2'}`,
            }}>
              {testResult.success ? '✓ ' : '✗ '}{testResult.text}
            </div>
          )}
        </div>
      </section>

      {/* Prompt / Schema / 报告 */}
      <section className="card">
        <h2>System Prompt 与输出格式</h2>
        <div style={{ display: 'flex', gap: 4, marginBottom: -1 }}>
          {(['prompt', 'schema', 'report'] as const).map((key) => {
            const labels = { prompt: 'System Prompt', schema: '输出格式要求', report: '最近一条报告' }
            return (
              <button
                key={key}
                onClick={() => setActiveTab(key)}
                style={{
                  padding: '6px 16px', border: '1px solid #d9e2ec', borderBottom: 'none',
                  borderRadius: '8px 8px 0 0', fontSize: 13, fontWeight: 500, cursor: 'pointer',
                  background: activeTab === key ? '#fff' : '#f0f4f8',
                  color: activeTab === key ? '#0b6e4f' : '#627d98',
                }}
              >{labels[key]}</button>
            )
          })}
        </div>
        <div style={{ border: '1px solid #d9e2ec', borderRadius: '0 8px 8px 8px', padding: 16 }}>
          {activeTab === 'prompt' && (
            <pre style={{ margin: 0, fontSize: 12, lineHeight: 1.7, whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 420, overflowY: 'auto' }}>
              {config.systemPrompt}
            </pre>
          )}
          {activeTab === 'schema' && (
            <pre style={{ margin: 0, fontSize: 12, lineHeight: 1.7, whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 420, overflowY: 'auto' }}>
              {JSON.stringify(config.outputSchema, null, 2)}
            </pre>
          )}
          {activeTab === 'report' && (
            config.latestReport
              ? <ReportView report={config.latestReport} />
              : <p style={{ fontSize: 13, color: '#9aa5b4' }}>暂无报告记录。</p>
          )}
        </div>
      </section>
    </div>
  )
}

function ReportView({ report }: { report: MedicalReport }) {
  const [showRaw, setShowRaw] = useState(false)
  const riskColors: Record<string, string> = { low: '#2a9d8f', medium: '#f4a261', high: '#e63946' }
  const riskLabels: Record<string, string> = { low: '低风险', medium: '中风险', high: '高风险' }
  const severityColors: Record<string, string> = { high: '#e63946', medium: '#f4a261', low: '#457b9d', info: '#8d99ae' }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, fontSize: 14 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <span style={{ color: '#627d98', fontSize: 12 }}>会话 {report.sessionId}</span>
        <span style={{ color: '#627d98', fontSize: 12 }}>{report.generatedAt}</span>
        {report.riskLevel && (
          <span style={{
            padding: '2px 12px', borderRadius: 20, fontSize: 12, fontWeight: 600,
            background: `${riskColors[report.riskLevel] ?? '#8d99ae'}22`,
            color: riskColors[report.riskLevel] ?? '#8d99ae',
            border: `1px solid ${riskColors[report.riskLevel] ?? '#8d99ae'}`,
          }}>{riskLabels[report.riskLevel] ?? report.riskLevel}</span>
        )}
        {report.confidence != null && (
          <span style={{ fontSize: 12, color: '#627d98' }}>置信度 {Math.round(report.confidence * 100)}%</span>
        )}
        {report.modelTrace && (
          <span style={{ fontSize: 12, color: '#9aa5b4' }}>
            {report.modelTrace.provider} · {report.modelTrace.status}
            {report.modelTrace.model ? ` · ${report.modelTrace.model}` : ''}
          </span>
        )}
      </div>

      <p style={{ margin: 0, lineHeight: 1.7 }}>{report.summary}</p>

      {report.findings.length > 0 && (
        <div>
          <div style={{ fontWeight: 600, marginBottom: 8 }}>主要发现</div>
          {report.findings.map((f, i) => (
            <div key={i} style={{ display: 'flex', gap: 8, alignItems: 'flex-start', marginBottom: 8, padding: '10px 12px', background: '#f8fafc', borderRadius: 10, border: '1px solid #dce3ea' }}>
              <span style={{ width: 8, height: 8, borderRadius: '50%', background: severityColors[f.severity] ?? '#8d99ae', flexShrink: 0, marginTop: 5 }} />
              <div>
                <div style={{ fontWeight: 500 }}>{f.title} <span style={{ fontSize: 12, color: severityColors[f.severity] ?? '#8d99ae' }}>{f.severity}</span></div>
                <div style={{ color: '#486581', marginTop: 2 }}>{f.detail}</div>
              </div>
            </div>
          ))}
        </div>
      )}

      {report.recommendations.length > 0 && (
        <div>
          <div style={{ fontWeight: 600, marginBottom: 8 }}>建议</div>
          {report.recommendations.map((r, i) => (
            <div key={i} style={{ marginBottom: 6 }}>• {r}</div>
          ))}
        </div>
      )}

      <div>
        <button
          onClick={() => setShowRaw(!showRaw)}
          style={{ fontSize: 12, padding: '4px 12px', border: '1px solid #bcccdc', borderRadius: 8, background: '#f0f4f8', color: '#334e68', cursor: 'pointer' }}
        >{showRaw ? '收起原始 JSON' : '查看原始 JSON'}</button>
        {showRaw && (
          <pre style={{ marginTop: 10, fontSize: 11, lineHeight: 1.6, whiteSpace: 'pre-wrap', wordBreak: 'break-word', maxHeight: 360, overflowY: 'auto', background: '#f8fafc', border: '1px solid #d9e2ec', borderRadius: 8, padding: 12 }}>
            {JSON.stringify(report, null, 2)}
          </pre>
        )}
      </div>
    </div>
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
