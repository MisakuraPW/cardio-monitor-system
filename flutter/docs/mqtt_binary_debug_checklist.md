# MQTT 二进制链路调试清单

这份清单只覆盖当前最短链路：

```text
ESP32 -> EMQX Broker -> 上位机实时波形
                    -> cloud_ingest 落库
```

## 1. 当前协议选择

现在 MQTT 波形推荐直接使用和 BLE 相同的 `BIO1` 二进制帧。

JSON 仍然保留，主要用于 MQTTX 手工调试；ESP32 正式发送波形时可以不再发 JSON 波形。

## 2. ESP32 应该发布到哪里

Broker：

```text
182.254.220.56:1883
```

推荐 topic：

```text
cardio/esp32-bio/waveform/bio1
```

也兼容：

```text
cardio/esp32-bio/telemetry_bin
cardio/esp32-bio/binary
```

注意：

- 上位机的 Device ID 当前默认是 `esp32-bio`。
- 所以 ESP32 的 topic 也应该使用 `cardio/esp32-bio/...`。
- EMQX 里的 Client ID 可以是 `esp32-bio-CBB0`，它不等于 topic 里的 deviceId。

## 3. BIO1 帧格式

所有整数均为 little-endian。

帧头固定 11 字节：

```text
magic: 4 bytes = "BIO1"
type:  1 byte  = 'E' / 'P' / 'I'
seq:   uint32
n:     uint16
```

ECG 单样本 12 字节：

```text
timestamp_us: uint64
raw_adc:      uint16
lod_p:        uint8
lod_n:        uint8
```

PPG 单样本 16 字节：

```text
timestamp_us: uint64
ir:           uint32
red:          uint32
```

IMU 单样本 20 字节：

```text
timestamp_us: uint64
ax:           int16
ay:           int16
az:           int16
gx:           int16
gy:           int16
gz:           int16
```

## 4. 上位机现在怎么显示

上位机 MQTT 已经支持：

- JSON: `cardio/{deviceId}/waveform/{channelKey}`
- BIO1 binary: `cardio/{deviceId}/waveform/bio1`
- BIO1 binary: `cardio/{deviceId}/telemetry_bin`
- BIO1 binary: `cardio/{deviceId}/binary`

只要收到合法 `BIO1` payload，就会自动识别通道：

```text
ecg
ppg_ir
ppg_red
imu_ax
imu_ay
imu_az
imu_gx
imu_gy
imu_gz
```

不需要先发 catalog。

## 5. 云端 ingest 怎么启动

服务器上进入部署目录：

```bash
cd /root/cardio-monitor/deploy
```

确认 `.env` 至少包含：

```env
CARDIO_MQTT_HOST=host.docker.internal
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_USERNAME=
CARDIO_MQTT_PASSWORD=
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

启动云端 ingest：

```bash
docker compose up -d --build cloud_ingest
```

查看 ingest 日志：

```bash
docker compose logs -f cloud_ingest
```

看到类似内容说明 ingest 已经订阅 Broker：

```text
[mqtt-ingest] connected rc=0, subscribing cardio/+/#
```

收到二进制后应出现：

```text
[mqtt-ingest] opened binary session ...
[mqtt-ingest] BIO1 esp32-bio: ...
```

## 6. 除了看波形，还应该调什么

### 6.1 EMQX Clients

打开：

```text
http://182.254.220.56:18083
```

确认至少有：

- ESP32 client
- Flutter Web client
- cardio-cloud-ingest client

### 6.2 EMQX Topic 订阅

在 Dashboard 或 MQTTX 里订阅：

```text
cardio/esp32-bio/#
```

确认 ESP32 确实持续发布二进制消息。

### 6.3 上位机状态日志

上位机连接 MQTT 后，应该看到类似：

```text
MQTT BIO1 binary stream active
```

如果 EMQX 有数据但上位机没波形，优先检查：

- topic 是否是 `cardio/esp32-bio/...`
- payload 是否以 `42 49 4F 31` 开头，也就是 `BIO1`
- timestamp 是否是微秒 `timestamp_us`

### 6.4 云端后台

打开管理后台：

```text
http://182.254.220.56:8080
```

检查：

- Devices 是否出现 `esp32-bio`
- Sessions 是否出现 `wifi_mqtt_binary`
- Session detail 里 raw chunks 是否增加

### 6.5 API 验证

Swagger：

```text
http://182.254.220.56:8000/docs
```

可检查：

- `GET /api/v1/admin/devices`
- `GET /api/v1/admin/sessions`
- `GET /api/v1/sessions/{id}`
- `GET /api/v1/sessions/{id}/raw`

## 7. 当前完成状态

已经支持：

- ESP32 二进制 MQTT -> 上位机实时波形
- ESP32 二进制 MQTT -> cloud_ingest 自动开会话
- cloud_ingest 自动识别通道目录
- cloud_ingest 自动写 raw chunks
- JSON 调试路径继续保留

后续可继续完善：

- 每次设备上线自动新建/关闭会话的生命周期策略
- 收到一定 raw chunks 后自动触发分析任务
- 云端通过 WebSocket/SSE 把 ingest 状态推给上位机或后台
- EMQX 认证、ACL、TLS/WSS 正式上线配置
