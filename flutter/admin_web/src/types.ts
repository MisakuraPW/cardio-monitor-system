export type SessionRecord = {
  id: string
  deviceId: string
  sourceMode: string
  channelKeys: string[]
  startedAt: string
  updatedAt: string
  userId?: string | null
  userName: string
  metadata: Record<string, unknown>
}

export type UserRecord = {
  userId: string
  userName: string
  sessionCount: number
  latestUpdatedAt: string
}

export type UploadRecord = {
  id: string
  sessionId: string
  status: string
  createdAt: string
  lastMessage: string
}

export type AnalysisJobRecord = {
  id: string
  sessionId: string
  status: string
  createdAt: string
  completedAt?: string | null
  summary: string
}

export type SegmentRecord = {
  id: string
  sessionId: string
  userId: string
  userName: string
  segmentIndex: number
  objectKey: string
  createdAt: string
  startTimestampMs: number
  endTimestampMs: number
  sampleCount: number
  channelKeys: string[]
  metrics: Record<string, unknown>
  channelSummaries: Record<string, unknown>
  metadata: Record<string, unknown>
}

export type SegmentChannelPayload = {
  channelKey: string
  sampleRate: number
  unit: string
  quality: number
  startTimestampMs: number
  endTimestampMs: number
  samples: number[]
  summary: Record<string, unknown>
}

export type SegmentDetail = SegmentRecord & {
  channels: SegmentChannelPayload[]
}

export type AdminSessionItem = {
  session: SessionRecord
  latestUpload?: UploadRecord | null
  latestJob?: AnalysisJobRecord | null
  hasReport: boolean
  rawChunkCount: number
  segmentCount: number
}

export type DeviceRecord = {
  deviceId: string
  sourceMode: string
  lastSeenAt: string
  lastStatus: string
  metadata: Record<string, unknown>
}

export type AlertRecord = {
  id: string
  sessionId: string
  deviceId: string
  severity: string
  message: string
  createdAt: string
  payload: Record<string, unknown>
}

export type AdminOverview = {
  deviceCount: number
  sessionCount: number
  uploadCount: number
  analysisJobCount: number
  reportCount: number
  rawChunkCount: number
  alertCount: number
  userCount: number
  segmentCount: number
  latestSessions: SessionRecord[]
}

export type SessionDetail = {
  session: SessionRecord
  uploads: UploadRecord[]
  jobs: AnalysisJobRecord[]
  report?: {
    summary: string
    confidence?: number | null
    recommendations: string[]
  } | null
  rawChunks: Array<{ id: string; channelKey: string; sourceType: string; sampleCount: number; objectKey: string }>
  segments: SegmentRecord[]
  alerts: AlertRecord[]
}
