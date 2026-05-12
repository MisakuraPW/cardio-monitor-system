import type {
  AdminOverview,
  AdminSessionItem,
  AlertRecord,
  DeviceRecord,
  SegmentDetail,
  SessionDetail,
  SessionRecord,
  UserRecord,
} from './types'

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://127.0.0.1:8000'
const ADMIN_TOKEN = import.meta.env.VITE_ADMIN_TOKEN ?? 'change-me'

async function requestJson<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set('X-Admin-Token', ADMIN_TOKEN)
  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...init,
    headers,
  })
  if (!response.ok) {
    throw new Error(`Request failed: ${response.status}`)
  }
  return (await response.json()) as T
}

export const api = {
  getOverview: () => requestJson<AdminOverview>('/api/v1/admin/overview'),
  getUsers: () => requestJson<UserRecord[]>('/api/v1/admin/users'),
  getUserSessions: (userId: string) => requestJson<SessionRecord[]>(`/api/v1/users/${userId}/sessions`),
  getSessions: () => requestJson<AdminSessionItem[]>('/api/v1/admin/sessions'),
  getSessionDetail: (sessionId: string) => requestJson<SessionDetail>(`/api/v1/admin/sessions/${sessionId}`),
  getSegmentDetail: (sessionId: string, segmentId: string) =>
    requestJson<SegmentDetail>(`/api/v1/sessions/${sessionId}/segments/${segmentId}`),
  analyzeSegment: (sessionId: string, segmentId: string) =>
    requestJson<{ report: { summary: string; confidence?: number | null; recommendations: string[] } }>(
      `/api/v1/sessions/${sessionId}/segments/${segmentId}/analyze`,
      { method: 'POST' },
    ),
  getSegmentCsvUrl: (sessionId: string, segmentId: string) =>
    `${API_BASE_URL}/api/v1/sessions/${sessionId}/segments/${segmentId}/csv`,
  getDevices: () => requestJson<DeviceRecord[]>('/api/v1/admin/devices'),
  getAlerts: () => requestJson<AlertRecord[]>('/api/v1/admin/alerts'),
}
