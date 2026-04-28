# ESP32 - 云端 - 上位机 WiFi/MQTT 三端联调清单

## 1. 目标与当前现实

你现在想调的目标是：

```text
ESP32 -> WiFi / MQTT -> 云端 -> 上位机
```

但根据当前仓库代码，**已经实现并且最容易先打通的链路**其实是：

```text
ESP32 -> MQTT Broker
           |-> 云端 ingest 订阅并落库
           |-> 上位机 MQTT 直连订阅并显示
```

也就是说，当前代码已经支持：

- `ESP32 -> Broker -> 上位机`
- `ESP32 -> Broker -> 云端 ingest`

但**还没有真正实现**：

- `云端把实时 MQTT 数据再转发给上位机`
- `上位机只连云端，不直连 Broker`

所以这份清单分成两层：

1. 先把“同一个 Broker 上三端都连上”的联调跑通
2. 再列出“严格云转发架构”还缺哪些功能

## 2. 阅读当前代码后的现状总结

### 2.1 上位机当前实现

Flutter Web 上位机当前 MQTT 适配器在：

- `flutter_app/lib/src/data_sources.dart`

当前行为：

- 使用 `MqttBrowserClient`
- 通过 **WebSocket MQTT** 连接 Broker
- 订阅以下主题：

```text
cardio/{deviceId}/status
cardio/{deviceId}/catalog
cardio/{deviceId}/waveform/+
cardio/{deviceId}/metrics
cardio/{deviceId}/alerts
```

当前上位机**真正处理**的主题：

- `status`
- `catalog`
- `waveform/+`
- `alerts`

当前 `metrics` 虽然订阅了，但没有形成有效显示链路。

另外，上位机当前 **按 JSON 解析 MQTT 载荷**。  
也就是说：

- MQTT 这条链路当前默认吃的是 JSON
- 不是 BLE 那套 `BIO1` 二进制帧

### 2.2 云端当前实现

云端相关代码在：

- `cloud_server/app/main.py`
- `cloud_server/app/mqtt_ingest.py`
- `cloud_server/app/mqtt_ingest_runner.py`
- `cloud_server/app/storage.py`

当前云端已经支持：

- REST API
- MQTT ingest 订阅服务
- SQLite 存储
- 原始波形分块入库
- 后台查询接口

云端 MQTT ingest 当前订阅：

```text
cardio/+/status
cardio/+/catalog
cardio/+/waveform/+
cardio/+/alerts
```

当前云端 ingest **没有处理**：

- `metrics`

### 2.3 当前最关键的架构结论

当前仓库并没有把 MQTT Broker 放进 `deploy/docker-compose.yml`。  
所以现在的系统里：

- `cloud_api` 不是 Broker
- `cloud_worker` 不是 Broker
- `admin_web` 不是 Broker

你必须单独准备一个 Broker，比如：

- EMQX
- Mosquitto

而且这个 Broker 最好同时支持：

- TCP MQTT：给云端 ingest 用
- WebSocket MQTT：给 Flutter Web 上位机用

## 3. 当前代码里最值得注意的“协议现实”

### 3.1 当前代码主协议

当前上位机和云端都更偏向这套主题：

```text
cardio/{deviceId}/status
cardio/{deviceId}/catalog
cardio/{deviceId}/control
cardio/{deviceId}/waveform/{channelKey}
cardio/{deviceId}/metrics
cardio/{deviceId}/alerts
```

### 3.2 当前最大的协议冲突

你仓库里的文档 `docs/README_WIFI_MQTT.md` 还写了另一套更偏设备侧的方案：

```text
esp32/trans1/telemetry
esp32/trans1/telemetry_bin
esp32/trans1/status
```

这和上位机/云端当前代码**不是一套**。

所以如果你现在就开始调 MQTT 三端联通，**必须先做一个选择**：

### 方案 A：先按当前代码跑通

推荐先这样做。

ESP32 先发 **JSON**，并且主题改成：

```text
cardio/{deviceId}/...
```

这样你几乎不用改上位机和云端，就能先把联调走通。

### 方案 B：坚持设备侧二进制 MQTT

如果你们已经决定 MQTT 也走 `BIO1` 二进制，那么还要补代码：

- 上位机 MQTT 适配器要支持二进制 payload 解包
- 云端 `mqtt_ingest.py` 也要支持二进制 payload 解包

这条路能做，但不是“当前就能直接跑”的状态。

### 当前建议

先用：

- MQTT JSON 打通三端
- BLE 继续用 `BIO1`

等三端稳定后，再统一收口到 MQTT 二进制。

如果 ESP32 侧已经有双发能力，最理想的是：

- MQTT 暂时 `JSON + binary` 双发
- 上位机/云端先吃 JSON
- 后续逐步切换到 binary

## 4. 先打通的最短可运行链路

推荐的第一阶段目标：

```text
ESP32 -> MQTT Broker -> 上位机
                   -> 云端 ingest
```

### 这个阶段的成功标准

满足以下 4 条就算打通：

1. ESP32 能发布 `status / catalog / waveform / alerts`
2. 上位机 MQTT 模式能看到通道和波形
3. 云端 ingest 能把同一批数据落库
4. 管理后台能查到 session / device / alert

## 5. 操作清单

## 5.1 第一步：准备 Broker

你需要一个 MQTT Broker。

要求：

- 云端 ingest 能通过 TCP 连上
- 上位机 Flutter Web 能通过 WebSocket 连上

建议参数：

- Topic Prefix：`cardio`
- MQTT TCP Port：`1883`
- MQTT WebSocket Port：按你的 Broker 实际配置
- WebSocket Path：按你的 Broker 实际配置

注意：

- 上位机默认 `WebSocket Path` 是 `/mqtt`
- 如果你的 Broker 不是这个路径，要在上位机界面里改

### 建议检查点

至少确认这两条是通的：

- 云端服务器到 Broker 的 `1883`
- 你电脑浏览器到 Broker 的 WebSocket 端口

## 5.2 第二步：启动云端 API

在 `cloud_server/` 目录下启动：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --port 8000
```

启动后检查：

- `http://127.0.0.1:8000/docs`
- `http://127.0.0.1:8000/api/v1/health`

## 5.3 第三步：配置云端 MQTT ingest 环境变量

云端 ingest 用这些环境变量：

```env
CARDIO_MQTT_HOST=你的Broker地址
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_USERNAME=
CARDIO_MQTT_PASSWORD=
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

这些配置来自：

- `cloud_server/app/config.py`

## 5.4 第四步：启动云端 MQTT ingest

在 `cloud_server/` 目录下执行：

```powershell
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m app.mqtt_ingest_runner
```

作用：

- 订阅 `cardio/+/status`
- 订阅 `cardio/+/catalog`
- 订阅 `cardio/+/waveform/+`
- 订阅 `cardio/+/alerts`

## 5.5 第五步：启动上位机

在 `flutter_app/` 下执行：

```powershell
G:\课设\FlutterSDK\flutter\bin\flutter.bat pub get
G:\课设\FlutterSDK\flutter\bin\flutter.bat run -d chrome
```

然后在 UI 中切到：

- `WiFi / MQTT`

填入：

- Broker Host
- Port
- WebSocket Path
- Device ID
- Username / Password（如果有）

注意：

- 这里的 `Device ID` 必须和 ESP32 发布主题里的 `deviceId` 一致
- 否则上位机会订到错误主题

## 5.6 第六步：先创建 session

这是当前代码里最容易忽略的点。

### 当前现实

云端 MQTT ingest **不会仅靠收到 waveform 自动创建 session**。  
它要求 MQTT 载荷里已经带有：

- `sessionId`

而且这个 `sessionId` 在云端必须先存在。

所以你要先走一次：

```text
POST /api/v1/ingest/mqtt/session/open
```

可以在 Swagger `/docs` 里直接发。

示例请求体：

```json
{
  "deviceId": "esp32-demo-01",
  "sourceMode": "wifi_mqtt",
  "channelKeys": ["ecg", "ppg_ir", "ppg_red", "imu_ax", "imu_ay", "imu_az"],
  "startedAt": "2026-04-19T12:00:00Z",
  "metadata": {
    "note": "mqtt debug"
  }
}
```

返回后，把里面的：

- `sessionId`

记录下来，并让 ESP32 后续发包时统一带这个 `sessionId`。

## 5.7 第七步：ESP32 按当前代码需要的 JSON 发布

### 1. status

主题：

```text
cardio/{deviceId}/status
```

示例：

```json
{
  "deviceId": "esp32-demo-01",
  "state": "streaming",
  "message": "ESP32 online"
}
```

### 2. catalog

主题：

```text
cardio/{deviceId}/catalog
```

示例：

```json
{
  "sessionId": "session_xxx",
  "channels": [
    {
      "key": "imu_gz",
      "label": "IMU GZ",
      "unit": "raw",
      "sampleRate": 100.0,
      "colorHex": "#A78BFA",
      "enabled": true
    }
  ]
}
```

### 3. waveform

主题：

```text
cardio/{deviceId}/waveform/{channelKey}
```

示例：

```json
{
  "deviceId": "esp32-demo-01",
  "sessionId": "session_xxx",
  "seq": 1,
  "timestampMs": 1713500000000,
  "sampleRate": 100.0,
  "unit": "raw",
  "quality": 1.0,
  "samples": [7, 8, 10, 9, 11, 10]
}
```

注意：

- `channelKey` 由主题尾部给出
- 当前上位机如果 payload 里没写 `channelKey`，会从 topic 补
- 当前云端 ingest 也是从 topic 提取 `channelKey`

### 4. alerts

主题：

```text
cardio/{deviceId}/alerts
```

示例：

```json
{
  "sessionId": "session_xxx",
  "severity": "warning",
  "message": "signal_quality_low"
}
```

## 6. 联调时每一端该看什么

## 6.1 看 ESP32

至少打印：

- WiFi 是否连上
- MQTT 是否连上
- 当前 `deviceId`
- 当前 `sessionId`
- 发布主题名
- 每帧 `seq`
- 每帧样本数

如果连上但没显示，先确认：

- 主题是不是 `cardio/...`
- `deviceId` 是否与上位机配置一致
- `sessionId` 是否已创建

## 6.2 看 Broker

建议用 MQTTX 或 `mosquitto_sub` 观察。

至少订阅：

```text
cardio/#
```

你应该看到：

- `status`
- `catalog`
- `waveform/...`
- `alerts`

如果 Broker 上都没有消息，就不用继续怀疑上位机或云端。

## 6.3 看上位机

上位机 UI 里重点看：

- 状态日志
- 通道列表是否出现
- 波形区是否出线

### 常见判断

- 有 `status`，但没有通道
  - 说明 `catalog` 没到，或格式不对

- 有通道，但没波形
  - 说明 `waveform` 没到，或 JSON 字段不对

- 有波形，但某些通道不显示
  - 说明那些通道的 topic 或 `channelKey` 不一致

## 6.4 看云端 ingest

MQTT ingest 进程正常时，它不一定打印很多内容。  
更可靠的方法是看 API 和后台结果。

优先查：

- `GET /api/v1/admin/devices`
- `GET /api/v1/admin/sessions`
- `GET /api/v1/admin/sessions/{id}`
- `GET /api/v1/admin/alerts`

如果有 session，但没有 catalog/raw chunk：

- 说明 session 创建了，但后续 MQTT ingest 没吃到 catalog/waveform

## 7. 推荐的调试顺序

严格按这个顺序，不要一上来三端同时猜。

1. 先确认 Broker 能收到 ESP32 消息  
   只看 `cardio/#`

2. 再确认上位机能收到并显示  
   先不看云端

3. 再确认云端 ingest 能落库  
   看 admin API

4. 最后再看上传分析、报告、后台展示

## 8. 当前最重要的待完善功能

## 8.1 严格意义上的“云端转发到上位机”还没有

当前上位机是直接连 Broker 的，不是从云端拿实时流。

要实现你真正想要的：

```text
ESP32 -> 云端 -> 上位机
```

还要补其中一种：

- 云端 WebSocket 实时推流
- 云端自己也作为 MQTT 网关转发
- 上位机通过云端 API / SSE / WebSocket 拉实时数据

## 8.2 当前 MQTT 二进制还没打通

现在 BLE 已经在用 `BIO1`。  
但 MQTT 这条链路里：

- 上位机 MQTT 适配器还按 JSON 解
- 云端 ingest 也还按 JSON 解

所以如果 ESP32 侧现在已经稳定转向 MQTT 二进制，当前代码还不够。

要补：

- `flutter_app/lib/src/data_sources.dart` 中 MQTT binary 解包
- `cloud_server/app/mqtt_ingest.py` 中 MQTT binary 解包

## 8.3 metrics 还没真正用起来

当前：

- 上位机订阅了 `metrics`
- 云端 ingest 没订阅 `metrics`
- 上位机 UI 也没有成型的 metrics 展示链路

这是一个待完善项。

## 8.4 session 创建还不够自动

现在必须先显式创建 session，然后 ESP32 再带着 `sessionId` 发。

后续更顺手的做法可以是：

- ESP32 上电后先调用云端 REST 开 session
- 或者 Broker 收到设备首次 `status` 后由云端自动建 session

## 8.5 部署层还缺 Broker 容器

当前 `deploy/docker-compose.yml` 没有：

- EMQX
- Mosquitto

所以正式上线前，最好把 Broker 也纳入部署编排。

## 9. 我给你的实际建议

### 当前最推荐的联调策略

先别急着让 MQTT 也切 `BIO1`。

先做：

1. ESP32 主题统一改成 `cardio/{deviceId}/...`
2. MQTT 先发 JSON
3. session 先通过 Swagger 创建
4. 把“Broker -> 上位机显示”和“Broker -> 云端落库”同时跑通

### 第二阶段再做

等这条稳定后，再做：

1. MQTT 二进制支持
2. metrics 入链路
3. 云端向上位机实时转发
4. 自动 session 管理

## 10. 最后给你的结论

如果只问“现在仓库里哪条路最容易先成功”：

答案是：

```text
ESP32(JSON) -> Broker -> 上位机
                     -> 云端 ingest
```

如果问“严格的 ESP32 -> 云端 -> 上位机 是否已经实现”：

答案是：

- 还没有完全实现
- 当前代码更像是“云端与上位机共同订阅 Broker”

所以现在联调不要把目标定得太远。  
先把这条最短路径跑通，后面的架构升级就会非常清晰。
