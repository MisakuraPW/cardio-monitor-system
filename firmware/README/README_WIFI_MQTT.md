# ESP32 WiFi/MQTT 输出协议说明（当前代码版）

本文档描述当前工程中 WiFi + MQTT 的真实输出行为，供你或其他 AI 直接对接解析。

适用代码范围：
- include/config.h
- src/main.cpp
- src/cloud_mqtt.cpp

## 1. 当前输出总开关

在 include/config.h 中：

- ENABLE_WIFI_OUTPUT
  - 1: 启用 WiFi/MQTT 输出
  - 0: 关闭 WiFi/MQTT 输出
- ENABLE_UART_OUTPUT
  - 1: 启用串口样本输出
  - 0: 关闭串口样本输出
- ENABLE_SERIAL_LOGGER
  - 1: 启用串口文本日志
  - 0: 关闭串口文本日志

- MQTT_PAYLOAD_MODE
  - 0: 仅 JSON telemetry
  - 1: 仅二进制 telemetry
  - 2: JSON + 二进制双发（兼容模式）

注意：
- WiFi 输出和串口输出已解耦，可独立开关。
- 如果只想云端传输，推荐配置：
  - ENABLE_WIFI_OUTPUT = 1
  - ENABLE_UART_OUTPUT = 0
  - ENABLE_SERIAL_LOGGER = 0

## 2. MQTT 基本参数

在 include/config.h 中配置：

- WIFI_SSID
- WIFI_PASSWORD
- MQTT_BROKER_HOST
- MQTT_BROKER_PORT
- MQTT_CLIENT_ID_PREFIX
- MQTT_TOPIC_TELEMETRY
- MQTT_TOPIC_STATUS

默认主题：
- Telemetry: esp32/trans1/telemetry
- Telemetry Binary: esp32/trans1/telemetry_bin
- Status: esp32/trans1/status

## 3. 数据流与任务关系（WiFi 方向）

1. 采样任务将 ECG/PPG/IMU 放入主队列。
2. packetizerTask 从主队列取样，并调用 cloud_mqtt::enqueueEcg/Ppg/Imu 入 MQTT 队列。
3. mqttTask 执行 cloud_mqtt::taskLoop，按固定周期发布。

当前调度特性：
- packetizerTask 在 core 1 上运行，批量取样以提升吞吐。
- mqttTask 在 core 0 上运行，优先级高于 packetizer，减少同核互抢。

## 4. MQTT 发布节拍与批量大小

在 src/cloud_mqtt.cpp：

- mqttTask 内部循环周期约 20ms（kMqttTaskPeriodTicks）。
- 单条消息按类型批量发送：
  - ECG 每批最多 24 点
  - PPG 每批最多 12 点
  - IMU 每批最多 12 点

在 src/main.cpp：

- packetizerTask 每轮批量从主队列取样（默认 ECG 8 / PPG 4 / IMU 4），降低 500Hz ECG 的拥塞风险。

## 5. Telemetry JSON 协议

每条 telemetry 消息包含一个 type 和一组 samples。

公共字段：
- device: 设备 ID（前缀 + 芯片后缀）
- type: ECG / PPG / IMU
- seq: 发布序号（全局递增）
- n: 本条 samples 数量
- samples: 二维数组

### 5.1 ECG

```json
{
  "device": "esp32-bio-ABCD",
  "type": "ECG",
  "seq": 1001,
  "n": 24,
  "samples": [
    [191011272, 4095, 1, 1],
    [191013297, 4090, 1, 1]
  ]
}
```

ECG 单点格式：
- [ts_us, raw_adc, lod_p, lod_n]

### 5.2 PPG

```json
{
  "device": "esp32-bio-ABCD",
  "type": "PPG",
  "seq": 1002,
  "n": 12,
  "samples": [
    [159501316, 103840, 104257],
    [159506316, 103859, 104262]
  ]
}
```

PPG 单点格式：
- [ts_us, ir, red]

### 5.3 IMU

```json
{
  "device": "esp32-bio-ABCD",
  "type": "IMU",
  "seq": 1003,
  "n": 12,
  "samples": [
    [210000000, -12, 104, 16390, 2, -1, 0],
    [210005000, -11, 103, 16388, 2, -1, 0]
  ]
}
```

IMU 单点格式：
- [ts_us, ax, ay, az, gx, gy, gz]

## 5.4 Telemetry 二进制协议

当 MQTT_PAYLOAD_MODE 为 1 或 2 时，设备会向 MQTT_TOPIC_TELEMETRY_BIN 发布二进制 payload。

二进制帧格式（小端）：

1. magic: 4 bytes，固定为 "BIO1"
2. type: 1 byte，'E' / 'P' / 'I'
3. seq: uint32_le
4. n: uint16_le
5. samples: 按 type 连续排列

各类型 sample 编码：

- ECG（12 bytes）
  - ts_us: uint64_le
  - raw_adc: uint16_le
  - lod_p: uint8
  - lod_n: uint8

- PPG（16 bytes）
  - ts_us: uint64_le
  - ir: uint32_le
  - red: uint32_le

- IMU（20 bytes）
  - ts_us: uint64_le
  - ax: int16_le
  - ay: int16_le
  - az: int16_le
  - gx: int16_le
  - gy: int16_le
  - gz: int16_le

说明：
- 双发模式（MQTT_PAYLOAD_MODE=2）下，JSON 与二进制使用同一批样本、同一 seq。
- status 仍为 JSON，不受该开关影响。

## 6. Status JSON 协议

status 周期由 MQTT_PUBLISH_PERIOD_MS 控制（默认 5000ms）。

```json
{
  "device": "esp32-bio-ABCD",
  "seq": 1200,
  "uptime_ms": 123456,
  "rssi": -45,
  "q": {"ecg": 120, "ppg": 30, "imu": 28},
  "drop": {"ecg": 0, "ppg": 2, "imu": 1},
  "ow": {"ecg": 10, "ppg": 5, "imu": 3}
}
```

字段说明：
- q.ecg / q.ppg / q.imu
  - 当前 MQTT 队列深度（不是传感器主队列深度）
- drop.ecg / drop.ppg / drop.imu
  - MQTT 入队失败累计计数（队列不可用或 send 失败）
- ow.ecg / ow.ppg / ow.imu
  - MQTT 队列满时丢最旧并覆盖的累计计数（更常见的“隐式丢包”来源）

## 7. 队列拥塞策略（非常关键）

当前代码采用“队列满时丢最旧，保留最新”：

- MQTT 入队：enqueueDroppingOldest

主队列行为：
- PPG/IMU 主队列入队：pushDroppingOldest
- ECG 主队列入队：xQueueSend 超时丢新（主队列满时会丢当前样本）

这能避免云端长期看到旧数据，降低“信号几乎不变”的风险。

## 8. 重连行为

WiFi 重连为非阻塞方式：
- 到重试时间就调用 WiFi.begin 后立即返回
- mqttTask 周期继续跑，不会因为单次重连卡住 10 秒

这能减少“断断续续”发送。

## 9. 给其他 AI 的对接提示

如果你把本项目交给其他 AI，请给它这些约束：

1. 不要改 telemetry/status 的 JSON 字段名和 samples 顺序，除非同步更新本 README。
2. 保持 type=ECG/PPG/IMU 的三类消息结构。
3. 保持队列满时“丢最旧保最新”的策略，避免回退为“丢新保旧”。
4. 保持 WiFi 重连非阻塞，避免发送线程长时间停顿。

## 10. 快速订阅与验证

建议同时订阅：
- esp32/trans1/telemetry
- esp32/trans1/status

验证要点：

1. telemetry 中 PPG/IMU 的 samples 数值应持续变化。
2. status.q 不应长期贴近上限。
3. status.drop 可短时增加，但不应长期高速增长。
