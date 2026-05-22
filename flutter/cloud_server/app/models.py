from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def make_id(prefix: str) -> str:
    return f"{prefix}-{uuid4().hex[:12]}"


class SessionCreate(BaseModel):
    deviceId: str
    sourceMode: str
    channelKeys: list[str] = Field(default_factory=list)
    startedAt: str = Field(default_factory=utcnow_iso)
    userId: str | None = None
    userName: str = '演示用户'
    metadata: dict[str, Any] = Field(default_factory=dict)


class SessionRecord(SessionCreate):
    id: str
    updatedAt: str


class UserRecord(BaseModel):
    userId: str
    userName: str
    sessionCount: int = 0
    latestUpdatedAt: str = ''


class UploadCreate(BaseModel):
    summary: dict[str, Any] = Field(default_factory=dict)
    excerpts: dict[str, Any] = Field(default_factory=dict)


class UploadRecord(BaseModel):
    id: str
    sessionId: str
    status: str
    createdAt: str
    lastMessage: str = ''


class AnalysisJobCreate(BaseModel):
    sessionId: str
    patientProfile: PatientProfile | None = None


class AnalysisJobRecord(BaseModel):
    id: str
    sessionId: str
    status: str
    createdAt: str
    completedAt: str | None = None
    summary: str = ''


class ReportFinding(BaseModel):
    title: str
    severity: str
    detail: str


class ModelTrace(BaseModel):
    provider: str
    route: str
    status: str
    model: str | None = None
    promptVersion: str | None = None
    note: str = ''


class PatientProfile(BaseModel):
    age: int | None = None
    gender: str | None = None
    medicalHistory: str | None = None


class MedicalReport(BaseModel):
    sessionId: str
    generatedAt: str
    summary: str
    recommendations: list[str] = Field(default_factory=list)
    findings: list[ReportFinding] = Field(default_factory=list)
    riskLevel: str | None = None  # 'low' | 'medium' | 'high' | None
    confidence: float | None = None
    modelTrace: ModelTrace | None = None


class ChannelDescriptorPayload(BaseModel):
    key: str
    label: str
    unit: str
    sampleRate: float
    colorHex: str = '#247BA0'
    enabled: bool = True


class ChannelCatalogCreate(BaseModel):
    sessionId: str
    deviceId: str
    sourceMode: str = 'wifi_mqtt'
    channels: list[ChannelDescriptorPayload] = Field(default_factory=list)


class ChannelCatalogRecord(ChannelCatalogCreate):
    id: str
    createdAt: str


class DeviceUpsert(BaseModel):
    deviceId: str
    sourceMode: str
    lastStatus: str = 'online'
    metadata: dict[str, Any] = Field(default_factory=dict)


class DeviceRecord(BaseModel):
    deviceId: str
    sourceMode: str
    lastSeenAt: str
    lastStatus: str
    metadata: dict[str, Any] = Field(default_factory=dict)


class IngestSessionOpen(BaseModel):
    deviceId: str
    sourceMode: str = 'wifi_mqtt'
    channelKeys: list[str] = Field(default_factory=list)
    startedAt: str = Field(default_factory=utcnow_iso)
    metadata: dict[str, Any] = Field(default_factory=dict)


class FrameBatchIngest(BaseModel):
    sessionId: str
    deviceId: str
    channelKey: str
    sampleRate: float
    unit: str = 'a.u.'
    quality: float = 1.0
    startTimestampMs: int
    endTimestampMs: int | None = None
    samples: list[float] = Field(default_factory=list)
    transport: str = 'mqtt'
    metadata: dict[str, Any] = Field(default_factory=dict)


class RawChunkRecord(BaseModel):
    id: str
    sessionId: str
    channelKey: str
    sourceType: str
    objectKey: str
    createdAt: str
    startTimestampMs: int
    endTimestampMs: int
    sampleCount: int
    metadata: dict[str, Any] = Field(default_factory=dict)


class SegmentChannelPayload(BaseModel):
    channelKey: str
    sampleRate: float
    unit: str = 'a.u.'
    quality: float = 1.0
    startTimestampMs: int
    endTimestampMs: int
    samples: list[float] = Field(default_factory=list)
    summary: dict[str, Any] = Field(default_factory=dict)


class SegmentUploadCreate(BaseModel):
    sessionId: str
    deviceId: str
    userId: str | None = None
    userName: str = '演示用户'
    segmentIndex: int
    startTimestampMs: int
    endTimestampMs: int
    channels: list[SegmentChannelPayload] = Field(default_factory=list)
    metrics: dict[str, Any] = Field(default_factory=dict)
    channelSummaries: dict[str, Any] = Field(default_factory=dict)
    metadata: dict[str, Any] = Field(default_factory=dict)


class SegmentRecord(BaseModel):
    id: str
    sessionId: str
    userId: str
    userName: str
    segmentIndex: int
    objectKey: str
    createdAt: str
    startTimestampMs: int
    endTimestampMs: int
    sampleCount: int
    channelKeys: list[str] = Field(default_factory=list)
    metrics: dict[str, Any] = Field(default_factory=dict)
    channelSummaries: dict[str, Any] = Field(default_factory=dict)
    metadata: dict[str, Any] = Field(default_factory=dict)


class SegmentDetail(SegmentRecord):
    channels: list[SegmentChannelPayload] = Field(default_factory=list)


class SegmentAnalysisResult(BaseModel):
    segment: SegmentRecord
    report: MedicalReport


class AlertCreate(BaseModel):
    sessionId: str
    deviceId: str
    severity: str
    message: str
    payload: dict[str, Any] = Field(default_factory=dict)


class AlertRecord(AlertCreate):
    id: str
    createdAt: str


class AdminOverview(BaseModel):
    deviceCount: int
    sessionCount: int
    uploadCount: int
    analysisJobCount: int
    reportCount: int
    rawChunkCount: int
    alertCount: int
    userCount: int = 0
    segmentCount: int = 0
    latestSessions: list[SessionRecord] = Field(default_factory=list)


class AdminSessionItem(BaseModel):
    session: SessionRecord
    latestUpload: UploadRecord | None = None
    latestJob: AnalysisJobRecord | None = None
    hasReport: bool = False
    rawChunkCount: int = 0
    segmentCount: int = 0


class SessionDetail(BaseModel):
    session: SessionRecord
    uploads: list[UploadRecord] = Field(default_factory=list)
    jobs: list[AnalysisJobRecord] = Field(default_factory=list)
    report: MedicalReport | None = None
    catalogs: list[ChannelCatalogRecord] = Field(default_factory=list)
    rawChunks: list[RawChunkRecord] = Field(default_factory=list)
    segments: list[SegmentRecord] = Field(default_factory=list)
    alerts: list[AlertRecord] = Field(default_factory=list)
