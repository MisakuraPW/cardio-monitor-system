# Cardio Monitor System Agent Handoff Context

这份文档用于把当前项目交接给另一个 agent。它不是面向用户的说明书，而是面向实现者的上下文包：项目做什么、现在有哪些模块、哪些功能已经做过、哪些地方还需要继续优化，以及运行/验证命令。

## 0. 当前目标

项目是一个课程设计/演示优先的心肺功能监测系统：

- ESP32 采集 ECG、PPG、IMU、温度等数据。
- ESP32 本地做 DSP，尤其是 ECG/PPG 滤波和基于 IMU 的 PPG 运动伪影抑制。
- 上位机 Flutter Web 负责实时显示、通道控制、自动分段上传、触发云端分析。
- 云端 FastAPI 负责会话、分段数据、CSV 下载、报告生成、管理后台查询。
- Admin Web 负责演示用户/会话/分段回放、下载 CSV、调用大模型/规则分析。
- DSP Debug Web 是独立的离线调参网页，不参与实时主链路。

演示优先级高于完整专业链路。当前最重要的工程目标是：WiFi 模式尽可能流畅，默认不实时输出 IMU 六轴，不画过多通道，不让云端上传/分析阻塞实时显示。

## 1. 仓库结构

```text
cardio-monitor-system/
  firmware/                  ESP32 PlatformIO 固件
    src/
      main.cpp               采样任务、DSP 调用、分发到 MQTT/BLE/UART
      cloud_mqtt.cpp         WiFi/MQTT 实时输出、控制命令、metrics
      ble_stream.cpp         BLE notify/control 输出
      signal_dsp.cpp         本地 DSP 算法
      ecg_adc.cpp            AD8232 ECG 采样
      ppg_max30102.cpp       MAX30102 PPG 采样
      imu_bmi160.cpp         BMI160 IMU 采样
      data_logger.cpp        本地日志/串口输出
    include/
      config.h               采样率、开关、MQTT/BLE 参数
      data_types.h           EcgSample/PpgSample/ImuSample 等结构
      dsp_config.h           DSP 默认参数
      signal_dsp.h           DSP 公共接口
    platformio.ini           esp32dev + Arduino + PubSubClient/NimBLE/MAX3010x

  flutter/
    flutter_app/             Flutter Web 上位机
      lib/src/
        dashboard_page.dart  上位机 UI、波形卡片、云端分析按钮
        monitor_controller.dart 数据缓存、自动分段上传、绘图刷新控制
        data_sources.dart    CSV/BLE/MQTT 数据源与 BIO1/BIO2 解码
        cloud_api_service.dart 云端 API 客户端
        models.dart          上位机数据模型
    cloud_server/            FastAPI 云端服务
      app/
        main.py              API 路由
        storage.py           SQLite + blob 文件存储
        models.py            Pydantic 模型
        analysis_service.py  分析任务/分段分析编排
        analysis_provider.py 规则/大模型 provider 抽象
        mqtt_ingest.py       MQTT ingest 预留/实现
      tests/                 storage/reporting 测试
    admin_web/               Vite React 管理后台
      src/App.tsx            用户/会话/分段/报告 UI
      src/api.ts             API 客户端
      src/types.ts           前端类型
    dsp_debug_web/           Vite React 离线 DSP 调参工具
      src/main.tsx           CSV 导入、参数调整、波形对比、参数导出
    deploy/
      docker-compose.yml     云端 API/worker/ingest/admin_web 部署
    docs/                    软件端、云端、通信、部署文档

  docs/
    DSP_ALGORITHMS_AND_TUNING.md
    DSP_ALGORITHMS_AND_TUNING_ZH.md
    AGENT_HANDOFF_CONTEXT.md 当前文档

  FlutterSDK/                本地复制的 Flutter SDK，根 .gitignore 已忽略
```

根目录 `.gitignore` 目前只忽略 `FlutterSDK/`。当前 `git status --short` 曾显示 `.claude/` 未跟踪；不要随意提交个人工具配置。

## 2. 端到端数据流

### 实时演示主链路

```text
ESP32 sensors
  -> firmware main.cpp sampling tasks
  -> signal_dsp.cpp local DSP
  -> cloud_mqtt.cpp MQTT binary publish
  -> MQTT broker
  -> Flutter MqttDataSourceAdapter
  -> MonitorController ring buffers
  -> Dashboard waveform painter
```

### 云端存储/回放链路

```text
Flutter MonitorController
  -> AutoSegmentUploader every ~20s
  -> FastAPI POST /api/v1/sessions/{session_id}/segments
  -> SQLite metadata + blob JSON/raw chunks
  -> Admin Web list users/sessions/segments
  -> segment playback / CSV download / analyze
```

### 大模型/报告链路

```text
Flutter button "分析最近分段"
  -> CloudApiService.analyzeSegment
  -> POST /api/v1/sessions/{session_id}/segments/{segment_id}/analyze
  -> analysis_service.process_segment_analysis
  -> analysis_provider
  -> MedicalReport saved in segment_reports
```

Admin Web 分段详情页也有“调用大模型/规则分析”按钮，同一路由。

## 3. 当前演示策略

当前系统明确偏向功能演示和流畅度：

- WiFi 实时模式默认只显示 3 条滤波通道：
  - `ecg_filtered`
  - `ppg_ir_filtered`
  - `ppg_red_filtered`
- IMU 六轴不作为 WiFi 实时波形输出，只在 ESP32 本地参与运动强度估计和 PPG-NLMS。
- ECG/PPG 原始数据是否保存/上传可以保留，但实时 UI 主路径尽量不处理原始高频多通道。
- 上位机自动分段上传默认按约 20 秒切段。每段约等于 ECG 500 Hz 的 10000 点。
- 上传失败时不能无限堆积，避免为了完整性拖死演示页面。
- 鼠标悬停取值只应在暂停回看时启用；实时滚动时关闭。

## 4. 固件重点上下文

### 4.1 采样与 DSP

入口在 `firmware/src/main.cpp`：

- `signal_dsp::begin()` 初始化 DSP。
- ECG 采样后调用 `signal_dsp::processEcg(processed)`。
- PPG 采样后调用 `signal_dsp::processPpg(processed)`。
- IMU 采样后调用 `signal_dsp::updateImu(s)`，IMU 仍可入 DSP，但演示模式下不走 WiFi 波形输出。
- 采样数据分发给 `cloud_mqtt::enqueue*` 和 `ble_stream::enqueue*`。

数据结构在 `firmware/include/data_types.h`：

- `EcgSample`: `raw_adc`, `filtered_adc`, `quality`, `flags`, lead-off 状态。
- `PpgSample`: `ir`, `red`, `filtered_ir`, `filtered_red`, `quality`, `flags`。
- `ImuSample`: acc/gyr 六轴。

### 4.2 DSP 算法

实现文件：`firmware/src/signal_dsp.cpp`  
说明文档：`docs/DSP_ALGORITHMS_AND_TUNING_ZH.md`

ECG 链路：

- 高通去基线漂移，默认约 0.5 Hz。
- 50 Hz notch，可开关。
- 低通抑制高频噪声，默认约 38 Hz。
- 简化 R 峰/心率估计。
- lead-off 时降低质量，不更新峰值状态。

PPG 链路：

- 高通去 DC/慢漂移。
- 低通平滑。
- IMU-NLMS 自适应滤波处理 IR/RED。
- 简化脉搏估计。

IMU 运动参考：

- 计算加速度模长。
- 高通去重力趋势。
- 低通得到 `motionLevel`。
- 运动过强时更倾向标记质量下降，而不是强行滤到“看起来干净”。

### 4.3 WiFi/MQTT

核心文件：`firmware/src/cloud_mqtt.cpp`

当前关键点：

- `kDemoWifiMode = true`
- IMU WiFi 实时队列默认关闭。
- 演示模式建议只发滤波二进制帧：
  - `cardio/{device}/waveform_bin/ecg_filtered`
  - `cardio/{device}/waveform_bin/ppg_filtered`
- 控制命令 `set_channels` 必须识别 `ecg_filtered`, `ppg_ir_filtered`, `ppg_red_filtered`，否则上位机只请求 filtered 通道时固件可能误关 ECG/PPG。
- `publishDiagTelemetry()` 会发布 metrics，包括队列、drop、overwrite、DSP 指标、质量和运动强度。

重要改进方向：

- 如果 MQTT 仍卡，优先考虑固件端进一步减 topic：把 ECG filtered + PPG filtered 合成一个多通道 binary frame/topic。
- 更进一步可换成 WiFi Binary WebSocket/TCP，减少 MQTT 多 topic 高频消息开销。
- BLE 主要用于调试/低速预览，不建议承担长期高频全通道演示。

## 5. Flutter 上位机重点上下文

核心文件：

- `flutter/flutter_app/lib/src/dashboard_page.dart`
- `flutter/flutter_app/lib/src/monitor_controller.dart`
- `flutter/flutter_app/lib/src/data_sources.dart`
- `flutter/flutter_app/lib/src/cloud_api_service.dart`
- `flutter/flutter_app/lib/src/models.dart`

### 5.1 数据源

`data_sources.dart` 包含：

- `MqttDataSourceAdapter`: WiFi/MQTT 实时接收。
- `BluetoothDataSourceAdapter`: BLE 接收和控制。
- `FileReplayAdapter`: CSV/文件回放。
- `_Bio1BinaryCodec`: 兼容旧 BIO1/BIO2 风格二进制帧解析。

当前 WiFi demo 模式应该只订阅 filtered 必需 topic，并且只允许 enabled channel 进入 controller。未启用通道应尽早丢弃，不做统计、不触发 UI。

### 5.2 控制器与缓存

`MonitorController` 负责：

- 当前会话和数据源模式。
- 每通道 `WaveformBuffer` 环形/裁剪缓存。
- `ChannelRuntimeStats` 丢包、缺口、延迟统计。
- 自动分段上传 `AutoSegmentUploader`。
- 云端 session 创建、segment 上传、最近分段分析。
- UI 刷新节流。

性能关键：

- 实时帧不应频繁 `notifyListeners()` 重建整个页面。
- 波形刷新应走独立 notifier 或局部 builder。
- 左侧配置/日志/诊断面板不应跟随每次波形刷新重建。
- `_buildWaveformSlice()` 应限制可见点数量，并用 min/max 或桶降采样。
- 实时模式不应该做 hover 查找、文字测量、排序 percentile 等重操作。

### 5.3 绘图

`dashboard_page.dart` 中的 `_WaveformCard` / `_WaveformPainter`：

- 默认只显示 filtered 三路。
- 实时滚动时隐藏 hover 文本和坐标标签。
- 暂停时启用鼠标取值。
- 线条绘制尽量简单：低 stroke width、关闭 antiAlias、避免 quadraticBezier。
- 若仍卡，下一步可以：
  - 进一步降低刷新率到 10-20 FPS。
  - 每个通道只画最近 4 秒。
  - 默认只画 ECG filtered + 一个 PPG filtered。
  - 把统计/日志刷新频率降到 1-2 Hz。
  - 若 Flutter Web 仍不够，可考虑独立 WebGL/uPlot/Canvas 波形页。

### 5.4 自动分段上传

模型在 `models.dart`：

- `SegmentChannelUpload`
- `SegmentUploadPayload`
- `SegmentRecord`
- `SegmentAnalysisResult`

控制逻辑在 `AutoSegmentUploader`：

- 默认每约 20 秒封口一个 segment。
- 每段包含用户、session、segmentIndex、start/end、channels、sampleRate、unit、quality、metrics。
- 上传成功后上位机裁剪本地旧缓存，只保留最近约 20-30 秒显示数据。
- 上传失败最多保留有限待上传队列，超过就丢弃最旧，避免 UI 卡死。
- 要防止乱序/迟到帧导致重复小段，例如 `#8` 有 1 点、21 点这种现象。应维护已关闭 segment index、封口 grace window、最小样本数阈值。

## 6. 云端 FastAPI 重点上下文

核心目录：`flutter/cloud_server/app`

### 6.1 API 路由

`main.py` 已包含：

- `POST /api/v1/sessions`
- `GET /api/v1/sessions/{session_id}`
- `POST /api/v1/sessions/{session_id}/segments`
- `GET /api/v1/sessions/{session_id}/segments`
- `GET /api/v1/sessions/{session_id}/segments/{segment_id}`
- `GET /api/v1/sessions/{session_id}/segments/{segment_id}/csv`
- `POST /api/v1/sessions/{session_id}/segments/{segment_id}/analyze`
- `GET /api/v1/sessions/{session_id}/segments/{segment_id}/report`
- `GET /api/v1/users`
- `GET /api/v1/users/{user_id}/sessions`
- `GET /api/v1/admin/*` 管理后台接口
- `POST /api/v1/ingest/mqtt/*` MQTT ingest 接口

### 6.2 存储

`storage.py`：

- SQLite 保存 sessions/users/uploads/jobs/reports/devices/alerts/segments/segment_reports 等元数据。
- 大段原始样本放在 blob JSON/raw chunk 文件中，避免大字段塞 SQLite。
- `create_segment()` 负责落段。
- `save_segment_report()` / `get_segment_report()` 负责分段报告。

### 6.3 分析/大模型

`analysis_service.py`：

- `process_analysis_job()` 处理旧上传报告。
- `process_segment_analysis()` 处理单段数据报告。
- 分段分析只应把摘要指标、质量分、少量 excerpt、异常候选点交给模型，不要把完整高频波形塞进 prompt。

`analysis_provider.py`：

- `ClosedSourceProvider`：OpenAI-compatible 风格 API 适配层。
- `OpenSourceProvider`：本地/开源模型适配层预留。
- 如果未配置 API key，应能返回规则分析/降级结果，不影响演示。

环境变量在 `config.py`：

```env
CARDIO_APP_ENV=production
CARDIO_ANALYSIS_EXECUTION_MODE=inline|queue
CARDIO_ANALYSIS_PROVIDER=closed_source
CARDIO_LLM_API_BASE_URL=
CARDIO_LLM_API_KEY=
CARDIO_LLM_MODEL=
CARDIO_LLM_PROMPT_VERSION=v1
CARDIO_ADMIN_TOKEN=
CARDIO_MQTT_HOST=
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

## 7. Admin Web 重点上下文

目录：`flutter/admin_web`

技术栈：Vite + React + TypeScript。

功能：

- 总览、用户、设备、会话、报告、任务、告警。
- 用户页：用户 -> 会话 -> 分段。
- 分段详情：轻量波形预览、CSV 下载、调用大模型/规则分析。

关键文件：

- `src/App.tsx`
- `src/api.ts`
- `src/types.ts`
- `src/styles.css`

注意：

- 如果页面报 `Request failed: 404`，通常是服务器 Docker 镜像还没更新到含 segment csv/analyze 路由的版本。
- 需要重新 `git pull` 后 `docker compose up -d --build`。

## 8. DSP Debug Web 重点上下文

目录：`flutter/dsp_debug_web`

用途：

- 独立离线调参，不集成进 Flutter 上位机。
- 导入 CSV。
- 映射 ECG/PPG/IMU/timestamp 列。
- 调节 ECG 高通/陷波/低通/R 峰阈值、PPG 高通/低通、NLMS taps/step/epsilon/motion threshold。
- 查看原始/滤波/运动参考/质量/峰值标记。
- 导出 `dsp_params.json` 或 C++ 常量块。

设计原因：

- 上位机实时绘图已经有性能压力，不应把复杂调参界面塞进实时 UI。

## 9. 常用运行命令

建议从仓库根目录开始：

```powershell
cd G:\课设\system\cardio-monitor-system
```

### 9.1 Flutter 上位机

```powershell
cd flutter\flutter_app
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" pub get
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" run -d chrome
```

分析：

```powershell
cd flutter\flutter_app
$env:FLUTTER_SUPPRESS_ANALYTICS='true'
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" analyze
```

Web build：

```powershell
cd flutter\flutter_app
$env:FLUTTER_SUPPRESS_ANALYTICS='true'
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" build web
```

### 9.2 云端服务

```powershell
cd flutter\cloud_server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

测试：

```powershell
cd flutter\cloud_server
python -m unittest discover -s tests
```

### 9.3 Admin Web

```powershell
cd flutter\admin_web
npm install
npm run dev
npm run build
```

### 9.4 DSP Debug Web

```powershell
cd flutter\dsp_debug_web
npm install
npm run dev
npm run build
```

### 9.5 固件

需要安装 PlatformIO：

```powershell
python -m platformio run -d firmware
```

如果本机未安装，会报：

```text
No module named platformio
```

## 10. 云端部署流程

服务器只部署云端 API、Worker、MQTT ingest、Admin Web。Flutter 上位机仍本地运行。

首次：

```bash
sudo dnf makecache
sudo dnf install -y git docker docker-compose-plugin
sudo systemctl enable --now docker

mkdir -p /root/cardio-monitor
cd /root/cardio-monitor
git clone <repo-url> cardio-monitor-system
cd cardio-monitor-system/flutter/deploy
cp .env.example .env
vi .env
sudo docker compose up -d --build
sudo docker compose ps
```

访问：

```text
FastAPI: http://<server-ip>:8000/docs
Admin Web: http://<server-ip>:8080
```

更新：

```bash
cd /root/cardio-monitor/cardio-monitor-system
git pull
cd flutter/deploy
sudo docker compose up -d --build
```

## 11. 当前已知问题与风险

1. WiFi/MQTT 仍可能卡：即使只发 filtered，MQTT 多 topic 高频消息仍有 overhead。最强优化是改成单 topic 多通道二进制帧，或换 WebSocket/TCP。
2. 自动分段曾出现 1 点/2 点小分段：原因一般是迟到帧/乱序帧导致旧 segmentIndex 被重新封口。实现者要检查 `AutoSegmentUploader` 是否有 closed index、grace window、min sample guard。
3. Admin Web 404：服务器镜像未更新，或 API route 未部署。重新 build compose。
4. Git 可能被 VS Code 占用：曾出现 `.git/index.lock` 或 permission 问题。提交前关闭 Source Control 刷新/等待 git 进程结束。
5. `FlutterSDK/` 在仓库目录但已被根 `.gitignore` 忽略。不要提交 Flutter SDK。
6. `.claude/` 是个人工具配置，不建议提交。
7. Python 测试会生成 `__pycache__`。不要提交 pyc。

## 12. 建议下一个 agent 的优先任务

### P0：确认当前工作树

```powershell
git status --short
```

不要随意 revert 用户已有改动。只清理明显生成物，例如 pycache/dist build 产物时先确认它们是否被跟踪。

### P1：固件 + 上位机实时链路压测

确认 WiFi 演示模式实际只收到：

- `waveform_bin/ecg_filtered`
- `waveform_bin/ppg_filtered`
- `metrics`
- `status`
- `alerts`

确认不再收到 IMU 六轴、原始 ECG、原始 PPG 的实时 topic。

### P2：若仍卡，改协议

当前最可能的下一步：

- 固件发布单个 topic：`cardio/{device}/waveform_bin/demo`
- 一个 frame 内包含 ECG filtered、PPG IR filtered、PPG RED filtered 三路。
- 上位机一次 decode 后分发到三个通道。
- 这样把多个 MQTT publish/subscribe/dispatch 合成一次。

如果还能接受更大改动：

- 使用 ESP32 WebSocket server/client 或 TCP binary stream。
- 上位机改用 WebSocket 数据源。
- MQTT 仅保留 status/metrics/alerts/control。

### P3：绘图继续降负

- 上位机默认只显示 `ecg_filtered` 和 `ppg_ir_filtered` 两条。
- 图表刷新降到 15-20 FPS。
- 统计卡片 1-2 Hz。
- 波形窗口 4 秒。
- 默认关闭日志滚动显示。
- 若 Flutter Web 依然卡，做独立 WebGL/uPlot 波形页面，只把 Flutter 用作控制面板。

### P4：云端演示闭环

确认：

- 上位机每 20 秒上传一段。
- Admin Web 每段能看到通道样本数。
- CSV 能下载并反向导回上位机回放。
- 上位机和 Admin Web 都能触发 segment analyze。
- 未配置大模型时仍返回规则报告。
- 配置 OpenAI-compatible API 后 `modelTrace` 记录模型名、prompt version、调用状态。

## 13. 验收 checklist

- 固件 PlatformIO build 通过。
- Flutter analyze 通过。
- Flutter Web build 通过。
- cloud_server unittest 通过。
- admin_web build 通过。
- dsp_debug_web build 通过。
- WiFi 实时模式 3-5 分钟不卡到不可用。
- 自动上传每约 20 秒产生一个有效 segment，segment 样本数合理。
- Admin Web 能下载任一 segment CSV。
- 上位机按钮能请求服务器分析最近 segment。
- Admin Web 分段详情按钮能请求分析并展示摘要。

## 14. 关键文档

- `docs/DSP_ALGORITHMS_AND_TUNING_ZH.md`: DSP 中文算法与调参说明。
- `flutter/docs/software_operation_guide.md`: 软件端操作指南。
- `flutter/docs/cloud_deployment_and_segment_upload.md`: 云端部署与分段上传。
- `flutter/docs/mqtt_three_end_integration_checklist.md`: 三端 MQTT 集成检查。
- `flutter/docs/mqtt_binary_debug_checklist.md`: MQTT 二进制链路调试。
- `firmware/README/README_WIFI_MQTT.md`: 固件 WiFi/MQTT 说明。
- `firmware/README/README_BLE.md`: 固件 BLE 说明。
- `firmware/README/BINARY_LOG_FORMAT.md`: 二进制日志格式。

