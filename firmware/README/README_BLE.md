# ESP32 BLE 输出协议说明（NimBLE 版本）
本文档说明当前工程的 BLE 输出方式，适用于 PC / 网页端（Web Bluetooth）接收。
适用代码范围：
- include/config.h
- include/ble_stream.h
- src/ble_stream.cpp
- src/main.cpp

## 1. 总开关与配置

在 `include/config.h` 中：

- `ENABLE_BLE_OUTPUT`
  - `1`：启用 BLE 输出
  - `0`：关闭 BLE 输出

- `BLE_DEVICE_NAME = "ESP32-bio"`
- `BLE_SERVICE_UUID = c0ad0001-8d2b-4d6f-9a1c-1c8a52f0a001`
- `BLE_NOTIFY_CHAR_UUID = c0ad1001-8d2b-4d6f-9a1c-1c8a52f0a001`
- `BLE_CONTROL_CHAR_UUID = c0ad1002-8d2b-4d6f-9a1c-1c8a52f0a001`
- `BLE_MTU_TARGET = 512`
- `BLE_NOTIFY_PAYLOAD_FALLBACK = 20`

## 2. BLE 服务与特征
- Service UUID: `c0ad0001-8d2b-4d6f-9a1c-1c8a52f0a001`
- Notify Characteristic UUID: `c0ad1001-8d2b-4d6f-9a1c-1c8a52f0a001`
- Control Characteristic UUID: `c0ad1002-8d2b-4d6f-9a1c-1c8a52f0a001`

说明：
- 连接后需订阅 Notify 特征（`c0ad1001-...`）才能持续接收数据。
- Control 特征当前已创建为可写（`WRITE | WRITE_NR`），用于后续控制指令扩展。

## 3. MTU 协商与分包
- 默认 ATT MTU 为 23（有效载荷 20 字节）。
- 设备会尝试协商到 `BLE_MTU_TARGET`（默认 512）。
- 每条 Notify 的有效载荷按 `MTU - 3` 计算。
- 单个 BIO1 帧可能拆为多个 Notify 包发送，接收端需按顺序重组。

## 4. 数据格式（复用 MQTT 二进制帧）
BLE 负载复用 MQTT 二进制格式：

1. `magic`：4 bytes，固定为 `"BIO1"`
2. `type`：1 byte，`'E' / 'P' / 'I'`
3. `seq`：`uint32_le`
4. `n`：`uint16_le`
5. `samples`：按 type 连续排列

样本结构：
- ECG（每样本 12 bytes）
  - `ts_us: uint64_le`
  - `raw_adc: uint16_le`
  - `lod_p: uint8`
  - `lod_n: uint8`

- PPG（每样本 16 bytes）
  - `ts_us: uint64_le`
  - `ir: uint32_le`
  - `red: uint32_le`

- IMU（每样本 20 bytes）
  - `ts_us: uint64_le`
  - `ax, ay, az: int16_le`
  - `gx, gy, gz: int16_le`

## 5. 接收端建议
1. 扫描并连接设备名 `ESP32-bio`。
2. 发现 Service UUID `c0ad0001-...`。
3. 订阅 Notify 特征 `c0ad1001-...`。
4. 按 BIO1 协议拼包并解析。
5. 根据 `seq` 统计丢包和乱序。

## 6. 常见问题

- 扫描不到设备：
  - 确认 `ENABLE_BLE_OUTPUT = 1` 并重新烧录。
  - 确认手机/电脑 BLE 已开启且具备定位权限（Android 常见）。
  - 确认设备已上电且未被其他客户端占用连接。
- 连接成功但无数据：
  - 确认已订阅 Notify 特征。
  - 确认接收端正确处理分包与重组。
