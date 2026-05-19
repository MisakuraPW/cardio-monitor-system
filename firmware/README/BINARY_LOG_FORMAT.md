# Binary Log Frame Format

This document describes the binary output format used by this project when `LOGGER_OUTPUT_MODE` is set to `2` in `include/config.h`.

## 1. Enable Binary Output

Set:

```c
#define LOGGER_OUTPUT_MODE 2
```

Important notes:

- `ENABLE_SERIAL_LOGGER` must be `1`.
- Optional mixed mode:
  - `LOGGER_OUTPUT_MODE 3` = binary frames + compact text (`E/P/I`) at the same time.
- Only enabled channels are emitted:
  - `ENABLE_ECG_OUTPUT`
  - `ENABLE_PPG_OUTPUT`
  - `ENABLE_IMU_OUTPUT`
- In binary mode, text status is disabled by default via `ENABLE_TEXT_STATUS 0`.

## 2. Frame Layout

Each sample is sent as one binary frame.

```text
+--------+--------+---------+--------+-------------------+-----------+
| SOF1   | SOF2   | Type    | Len    | Payload (Len bytes)| Checksum |
| 0xA5   | 0x5A   | 1 byte  | 1 byte | variable          | 1 byte   |
+--------+--------+---------+--------+-------------------+-----------+
```

- SOF1: `0xA5`
- SOF2: `0x5A`
- Type: ASCII char
  - `0x45` (`'E'`) for ECG
  - `0x50` (`'P'`) for PPG
  - `0x49` (`'I'`) for IMU
  - `0x54` (`'T'`) for M601 temperature
- Len: payload length in bytes
- Checksum: XOR of `Type`, `Len`, and all payload bytes

## 3. Payload Definitions (Little Endian)

`#pragma pack(push, 1)` is used, so there is no padding.
All multi-byte numbers are little-endian on ESP32.

### 3.1 ECG (`Type='E'`, `Len=12`)

```text
offset  size  type      field
0       8     uint64_t  ts_us
8       2     uint16_t  raw_adc
10      1     uint8_t   lead_off_plus (0/1)
11      1     uint8_t   lead_off_minus (0/1)
```

Total frame size: `2 + 1 + 1 + 12 + 1 = 17 bytes`

### 3.2 PPG (`Type='P'`, `Len=16`)

```text
offset  size  type      field
0       8     uint64_t  ts_us
8       4     uint32_t  ir
12      4     uint32_t  red
```

Total frame size: `2 + 1 + 1 + 16 + 1 = 21 bytes`

### 3.3 IMU (`Type='I'`, `Len=20`)

```text
offset  size  type      field
0       8     uint64_t  ts_us
8       2     int16_t   acc_x
10      2     int16_t   acc_y
12      2     int16_t   acc_z
14      2     int16_t   gyr_x
16      2     int16_t   gyr_y
18      2     int16_t   gyr_z
```

Total frame size: `2 + 1 + 1 + 20 + 1 = 25 bytes`

### 3.4 Temperature (`Type='T'`, `Len=15`)

```text
offset  size  type      field
0       8     uint64_t  ts_us
8       2     int16_t   raw
10      4     float     temp_c
14      1     uint8_t   flags
```

`raw` is the signed 16-bit M601 temperature register value. `temp_c` is calculated as `raw / 256.0f + 40.0f`.

Total frame size: `2 + 1 + 1 + 15 + 1 = 20 bytes`

## 4. Parser Recommendations

- Parse as a stream, not line-by-line.
- Search for SOF bytes `A5 5A` to align.
- Read `Type` and `Len`.
- Read `Len` payload bytes and `1` checksum byte.
- Validate checksum (`xor(type, len, payload...)`).
- If checksum fails, shift by one byte and re-sync on next SOF.

## 5. Timestamp Unit

- `ts_us` is microseconds (`uint64_t`).
- Use it as the primary timeline for multi-sensor alignment.

## 6. Source of Truth in Code

- Binary frame writer and payload structs:
  - `src/data_logger.cpp`
- Mode switch macros:
  - `include/config.h`
