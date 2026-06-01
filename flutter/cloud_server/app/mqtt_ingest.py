from __future__ import annotations

import json
import struct
import time
import zlib
from dataclasses import dataclass
from typing import Any

from .models import (
    AlertCreate,
    ChannelCatalogCreate,
    ChannelDescriptorPayload,
    DeviceUpsert,
    FrameBatchIngest,
    SessionCreate,
)
from .storage import SQLiteStorage

try:
    import paho.mqtt.client as mqtt
except ImportError:  # pragma: no cover
    mqtt = None


@dataclass
class _BinaryChannel:
    key: str
    label: str
    unit: str
    sample_rate: float
    color_hex: str


@dataclass
class _BinaryFrame:
    channel_key: str
    unit: str
    sample_rate: float
    start_timestamp_ms: int
    end_timestamp_ms: int
    samples: list[float]
    seq: int
    frame_version: int = 1
    decode_status: str = 'ok'


@dataclass
class _BinaryBatch:
    channels: list[_BinaryChannel]
    frames: list[_BinaryFrame]

    @property
    def is_empty(self) -> bool:
        return not self.channels and not self.frames


class MqttIngestService:
    def __init__(self, storage: SQLiteStorage, topic_prefix: str = 'cardio') -> None:
        self.storage = storage
        self.topic_prefix = topic_prefix.rstrip('/')
        self._binary_sessions: dict[str, str] = {}
        self._binary_channel_keys: dict[str, set[str]] = {}

    def handle_topic_message(self, topic: str, payload: str | bytes) -> None:
        payload_bytes = payload if isinstance(payload, bytes) else payload.encode('utf-8')
        segments = topic.split('/')
        if len(segments) < 3 or segments[0] != self.topic_prefix:
            return

        device_id = segments[1]
        channel_or_topic = '/'.join(segments[2:])
        if self._is_binary_topic(channel_or_topic) and _looks_like_bio(payload_bytes):
            self._handle_binary_payload(device_id, payload_bytes)
            return

        try:
            body = json.loads(payload_bytes.decode('utf-8'))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            print(f'[mqtt-ingest] ignored invalid payload topic={topic}: {error}', flush=True)
            return

        if channel_or_topic == 'status':
            self.storage.upsert_device(
                DeviceUpsert(
                    deviceId=device_id,
                    sourceMode='wifi_mqtt',
                    lastStatus=str(body.get('state', 'online')),
                    metadata=body,
                )
            )
            return

        if channel_or_topic == 'catalog':
            session_id = body.get('sessionId')
            if not session_id:
                return
            channels = [ChannelDescriptorPayload(**item) for item in body.get('channels', [])]
            self.storage.save_channel_catalog(
                ChannelCatalogCreate(
                    sessionId=session_id,
                    deviceId=device_id,
                    sourceMode='wifi_mqtt',
                    channels=channels,
                )
            )
            return

        if channel_or_topic.startswith('waveform/'):
            session_id = body.get('sessionId')
            if not session_id:
                return
            channel_key = channel_or_topic.split('/', 1)[1]
            self.storage.ingest_frame_batch(
                FrameBatchIngest(
                    sessionId=session_id,
                    deviceId=device_id,
                    channelKey=channel_key,
                    sampleRate=float(body.get('sampleRate', 0) or 0),
                    unit=str(body.get('unit', 'a.u.')),
                    quality=float(body.get('quality', 1) or 1),
                    startTimestampMs=int(body.get('timestampMs', 0) or 0),
                    endTimestampMs=int(body.get('endTimestampMs', body.get('timestampMs', 0)) or 0),
                    samples=[float(item) for item in body.get('samples', [])],
                    transport='mqtt',
                    metadata={'seq': body.get('seq')},
                )
            )
            return

        if channel_or_topic == 'alerts':
            session_id = body.get('sessionId')
            if not session_id:
                return
            self.storage.create_alert(
                AlertCreate(
                    sessionId=session_id,
                    deviceId=device_id,
                    severity=str(body.get('severity', 'info')),
                    message=str(body.get('message', 'mqtt_alert')),
                    payload=body,
                )
            )

    def _handle_binary_payload(self, device_id: str, payload_bytes: bytes) -> None:
        received_at_ms = int(time.time() * 1000)
        batch = _decode_bio(payload_bytes)
        if batch.is_empty:
            print(f'[mqtt-ingest] invalid BIO payload from {device_id}', flush=True)
            return

        session_id = self._ensure_binary_session(
            device_id,
            [channel.key for channel in batch.channels],
        )
        self.storage.upsert_device(
            DeviceUpsert(
                deviceId=device_id,
                sourceMode='wifi_mqtt_binary',
                lastStatus='online',
                metadata={'transport': 'mqtt', 'payload': 'BIO'},
            )
        )
        self._save_binary_catalog_if_needed(device_id, session_id, batch.channels)

        for frame in batch.frames:
            self.storage.ingest_frame_batch(
                FrameBatchIngest(
                    sessionId=session_id,
                    deviceId=device_id,
                    channelKey=frame.channel_key,
                    sampleRate=frame.sample_rate,
                    unit=frame.unit,
                    quality=1.0,
                    startTimestampMs=frame.start_timestamp_ms,
                    endTimestampMs=frame.end_timestamp_ms,
                    samples=frame.samples,
                    transport='mqtt_binary',
                    metadata={
                        'seq': frame.seq,
                        'payload': f'BIO{frame.frame_version}',
                        'frameVersion': frame.frame_version,
                        'decodeStatus': frame.decode_status,
                        'ingestReceivedAtMs': received_at_ms,
                        'ingestLatencyMs': max(0, received_at_ms - frame.end_timestamp_ms),
                    },
                )
            )
        print(
            f'[mqtt-ingest] BIO {device_id}: {len(batch.frames)} frames, session={session_id}',
            flush=True,
        )

    def _ensure_binary_session(self, device_id: str, channel_keys: list[str]) -> str:
        existing = self._binary_sessions.get(device_id)
        if existing:
            return existing

        session = self.storage.create_session(
            SessionCreate(
                deviceId=device_id,
                sourceMode='wifi_mqtt_binary',
                channelKeys=channel_keys,
            )
        )
        self._binary_sessions[device_id] = session.id
        self._binary_channel_keys[device_id] = set()
        print(f'[mqtt-ingest] opened binary session {session.id} for {device_id}', flush=True)
        return session.id

    def _save_binary_catalog_if_needed(
        self,
        device_id: str,
        session_id: str,
        channels: list[_BinaryChannel],
    ) -> None:
        known = self._binary_channel_keys.setdefault(device_id, set())
        incoming_keys = {channel.key for channel in channels}
        if incoming_keys.issubset(known):
            return

        known.update(incoming_keys)
        self.storage.save_channel_catalog(
            ChannelCatalogCreate(
                sessionId=session_id,
                deviceId=device_id,
                sourceMode='wifi_mqtt_binary',
                channels=[
                    ChannelDescriptorPayload(
                        key=channel.key,
                        label=channel.label,
                        unit=channel.unit,
                        sampleRate=channel.sample_rate,
                        colorHex=channel.color_hex,
                        enabled=True,
                    )
                    for channel in channels
                ],
            )
        )

    def _is_binary_topic(self, channel_or_topic: str) -> bool:
        return (
            channel_or_topic.startswith('waveform/')
            or channel_or_topic.startswith('waveform_bin/')
            or channel_or_topic in {'telemetry_bin', 'binary'}
        )


def _decode_bio(payload: bytes) -> _BinaryBatch:
    channels: dict[str, _BinaryChannel] = {}
    frames: list[_BinaryFrame] = []
    cursor = 0

    while cursor <= len(payload) - 11:
        bio1_index = payload.find(b'BIO1', cursor)
        bio2_index = payload.find(b'BIO2', cursor)
        candidates = [item for item in (bio1_index, bio2_index) if item >= 0]
        magic_index = min(candidates) if candidates else -1
        if magic_index < 0 or magic_index + 11 > len(payload):
            break

        is_bio2 = bio2_index == magic_index
        header_len = 19 if is_bio2 else 11
        if magic_index + header_len > len(payload):
            break

        type_code = chr(payload[magic_index + (5 if is_bio2 else 4)])
        sample_size = _sample_size_for_type(type_code)
        if sample_size is None:
            cursor = magic_index + 1
            continue

        seq = struct.unpack_from('<I', payload, magic_index + (7 if is_bio2 else 5))[0]
        sample_count = struct.unpack_from('<H', payload, magic_index + (11 if is_bio2 else 9))[0]
        payload_len = (
            struct.unpack_from('<H', payload, magic_index + 13)[0]
            if is_bio2
            else sample_count * sample_size
        )
        frame_length = header_len + payload_len
        if sample_count == 0 or magic_index + frame_length > len(payload):
            break
        if payload_len != sample_count * sample_size:
            cursor = magic_index + 1
            continue

        decode_status = 'ok'
        if is_bio2:
            expected_crc = struct.unpack_from('<I', payload, magic_index + 15)[0]
            actual_crc = zlib.crc32(payload[magic_index + header_len : magic_index + frame_length]) & 0xFFFFFFFF
            if actual_crc != expected_crc:
                decode_status = 'crc_error'

        frame = memoryview(payload)[magic_index : magic_index + frame_length]
        if type_code == 'E':
            _decode_ecg(frame, seq, sample_count, sample_size, channels, frames, header_len, 2 if is_bio2 else 1, decode_status)
        elif type_code == 'F':
            _decode_ecg(
                frame,
                seq,
                sample_count,
                sample_size,
                channels,
                frames,
                header_len,
                2 if is_bio2 else 1,
                decode_status,
                channel_key='ecg_filtered',
                label='ECG Filtered',
                color_hex='#D94F70',
            )
        elif type_code == 'P':
            _decode_ppg(frame, seq, sample_count, sample_size, channels, frames, header_len, 2 if is_bio2 else 1, decode_status)
        elif type_code == 'Q':
            _decode_ppg(
                frame,
                seq,
                sample_count,
                sample_size,
                channels,
                frames,
                header_len,
                2 if is_bio2 else 1,
                decode_status,
                ir_key='ppg_ir_filtered',
                red_key='ppg_red_filtered',
                ir_label='PPG IR Filtered',
                red_label='PPG RED Filtered',
            )
        elif type_code == 'I':
            _decode_imu(frame, seq, sample_count, sample_size, channels, frames, header_len, 2 if is_bio2 else 1, decode_status)

        cursor = magic_index + frame_length

    return _BinaryBatch(channels=list(channels.values()), frames=frames)


def _decode_ecg(
    frame: memoryview,
    seq: int,
    sample_count: int,
    sample_size: int,
    channels: dict[str, _BinaryChannel],
    frames: list[_BinaryFrame],
    payload_offset: int,
    frame_version: int,
    decode_status: str,
    channel_key: str = 'ecg',
    label: str = 'ECG',
    color_hex: str = '#F25F5C',
) -> None:
    timestamps_us: list[int] = []
    samples: list[float] = []
    for index in range(sample_count):
        offset = payload_offset + index * sample_size
        timestamps_us.append(struct.unpack_from('<Q', frame, offset)[0])
        samples.append(float(struct.unpack_from('<H', frame, offset + 8)[0]))

    sample_rate = _estimate_sample_rate(timestamps_us, 500)
    channels[channel_key] = _channel(channel_key, label, 'adc', sample_rate, color_hex)
    frames.append(_frame(channel_key, 'adc', sample_rate, timestamps_us, samples, seq, frame_version, decode_status))


def _decode_ppg(
    frame: memoryview,
    seq: int,
    sample_count: int,
    sample_size: int,
    channels: dict[str, _BinaryChannel],
    frames: list[_BinaryFrame],
    payload_offset: int,
    frame_version: int,
    decode_status: str,
    ir_key: str = 'ppg_ir',
    red_key: str = 'ppg_red',
    ir_label: str = 'PPG IR',
    red_label: str = 'PPG RED',
) -> None:
    timestamps_us: list[int] = []
    ir_samples: list[float] = []
    red_samples: list[float] = []
    for index in range(sample_count):
        offset = payload_offset + index * sample_size
        timestamps_us.append(struct.unpack_from('<Q', frame, offset)[0])
        ir_samples.append(float(struct.unpack_from('<I', frame, offset + 8)[0]))
        red_samples.append(float(struct.unpack_from('<I', frame, offset + 12)[0]))

    sample_rate = _estimate_sample_rate(timestamps_us, 200)
    channels[ir_key] = _channel(ir_key, ir_label, 'count', sample_rate, '#247BA0')
    channels[red_key] = _channel(red_key, red_label, 'count', sample_rate, '#C84C5A')
    frames.append(_frame(ir_key, 'count', sample_rate, timestamps_us, ir_samples, seq, frame_version, decode_status))
    frames.append(_frame(red_key, 'count', sample_rate, timestamps_us, red_samples, seq, frame_version, decode_status))


def _decode_imu(
    frame: memoryview,
    seq: int,
    sample_count: int,
    sample_size: int,
    channels: dict[str, _BinaryChannel],
    frames: list[_BinaryFrame],
    payload_offset: int,
    frame_version: int,
    decode_status: str,
) -> None:
    timestamps_us: list[int] = []
    samples = {
        'imu_ax': [],
        'imu_ay': [],
        'imu_az': [],
        'imu_gx': [],
        'imu_gy': [],
        'imu_gz': [],
    }
    for index in range(sample_count):
        offset = payload_offset + index * sample_size
        timestamps_us.append(struct.unpack_from('<Q', frame, offset)[0])
        samples['imu_ax'].append(float(struct.unpack_from('<h', frame, offset + 8)[0]))
        samples['imu_ay'].append(float(struct.unpack_from('<h', frame, offset + 10)[0]))
        samples['imu_az'].append(float(struct.unpack_from('<h', frame, offset + 12)[0]))
        samples['imu_gx'].append(float(struct.unpack_from('<h', frame, offset + 14)[0]))
        samples['imu_gy'].append(float(struct.unpack_from('<h', frame, offset + 16)[0]))
        samples['imu_gz'].append(float(struct.unpack_from('<h', frame, offset + 18)[0]))

    sample_rate = _estimate_sample_rate(timestamps_us, 100)
    metadata = {
        'imu_ax': ('IMU AX', '#2A9D8F'),
        'imu_ay': ('IMU AY', '#36B7A1'),
        'imu_az': ('IMU AZ', '#55C7AE'),
        'imu_gx': ('IMU GX', '#7B6DFF'),
        'imu_gy': ('IMU GY', '#9A7CFF'),
        'imu_gz': ('IMU GZ', '#B792FF'),
    }
    for key, values in samples.items():
        label, color = metadata[key]
        channels[key] = _channel(key, label, 'raw', sample_rate, color)
        frames.append(_frame(key, 'raw', sample_rate, timestamps_us, values, seq, frame_version, decode_status))


def _frame(
    channel_key: str,
    unit: str,
    sample_rate: float,
    timestamps_us: list[int],
    samples: list[float],
    seq: int,
    frame_version: int,
    decode_status: str,
) -> _BinaryFrame:
    return _BinaryFrame(
        channel_key=channel_key,
        unit=unit,
        sample_rate=sample_rate,
        start_timestamp_ms=timestamps_us[0] // 1000,
        end_timestamp_ms=timestamps_us[-1] // 1000,
        samples=samples,
        seq=seq,
        frame_version=frame_version,
        decode_status=decode_status,
    )


def _channel(
    key: str,
    label: str,
    unit: str,
    sample_rate: float,
    color_hex: str,
) -> _BinaryChannel:
    return _BinaryChannel(
        key=key,
        label=label,
        unit=unit,
        sample_rate=sample_rate,
        color_hex=color_hex,
    )


def _looks_like_bio(payload: bytes) -> bool:
    return payload.find(b'BIO1') >= 0 or payload.find(b'BIO2') >= 0


def _sample_size_for_type(type_code: str) -> int | None:
    if type_code in {'E', 'F'}:
        return 12
    if type_code in {'P', 'Q'}:
        return 16
    if type_code == 'I':
        return 20
    return None


def _estimate_sample_rate(timestamps_us: list[int], fallback: float) -> float:
    if len(timestamps_us) < 2:
        return fallback
    deltas = [
        timestamps_us[index] - timestamps_us[index - 1]
        for index in range(1, len(timestamps_us))
        if timestamps_us[index] > timestamps_us[index - 1]
    ]
    if not deltas:
        return fallback
    return 1_000_000.0 / (sum(deltas) / len(deltas))


def run_forever(
    storage: SQLiteStorage,
    host: str,
    port: int,
    topic_prefix: str,
    username: str = '',
    password: str = '',
) -> None:  # pragma: no cover
    if mqtt is None:
        raise RuntimeError('paho-mqtt is not installed. Please install requirements.txt first.')

    service = MqttIngestService(storage=storage, topic_prefix=topic_prefix)
    client = mqtt.Client()
    if username:
        client.username_pw_set(username=username, password=password or None)

    def on_connect(client_obj: Any, userdata: Any, flags: Any, rc: int) -> None:
        print(f'[mqtt-ingest] connected rc={rc}, subscribing {topic_prefix}/+/#', flush=True)
        client_obj.subscribe(f'{topic_prefix}/+/status')
        client_obj.subscribe(f'{topic_prefix}/+/catalog')
        client_obj.subscribe(f'{topic_prefix}/+/waveform/#')
        client_obj.subscribe(f'{topic_prefix}/+/waveform_bin/#')
        client_obj.subscribe(f'{topic_prefix}/+/telemetry_bin')
        client_obj.subscribe(f'{topic_prefix}/+/binary')
        client_obj.subscribe(f'{topic_prefix}/+/alerts')

    def on_message(client_obj: Any, userdata: Any, msg: Any) -> None:
        service.handle_topic_message(msg.topic, bytes(msg.payload))

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(host, port, 60)
    client.loop_forever()
