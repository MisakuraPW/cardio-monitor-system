# 软件端操作指南

本文只覆盖软件部分：Flutter 上位机、云端 FastAPI 服务、管理后台、DSP 调参网页。固件编译、烧录和接线不在本文范围内。

建议所有命令都从仓库根目录开始：

```powershell
cd G:\课设\system\cardio-monitor-system
```

## 推荐启动顺序

演示时建议按这个顺序打开：

1. 云端 FastAPI 服务
2. Flutter 上位机
3. 管理后台，按需打开
4. DSP 调参网页，按需打开

实时演示主链路是：

```text
ESP32 -> MQTT Broker -> Flutter 上位机
                \-> 云端 ingest / 数据库 / 管理后台
```

DSP 调参网页是离线调参工具，不参与实时链路。

## 云端服务

首次启动：

```powershell
cd flutter\cloud_server
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

之后如果 `.venv` 已经建好，只需要：

```powershell
cd flutter\cloud_server
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

服务启动后常用地址：

- API 根地址：`http://127.0.0.1:8000`
- FastAPI 文档：`http://127.0.0.1:8000/docs`

使用方式：

- 保持这个 PowerShell 窗口不要关闭。
- Flutter 上位机上传数据、查询报告、触发分析任务时，需要这个服务处于运行状态。
- 管理后台也依赖这个服务读取设备、会话、报告和告警数据。

如果需要让服务器从 MQTT 接收并入库，可另开一个 PowerShell 窗口运行：

```powershell
cd flutter\cloud_server
$env:PYTHONPATH = (Get-Location)
.\.venv\Scripts\python.exe -m app.mqtt_ingest_runner
```

功能演示时，如果只展示上位机实时波形，可以先不启动 MQTT ingest。

## Flutter 上位机

启动命令：

```powershell
cd flutter\flutter_app
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" pub get
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" run -d chrome
```

如果本机 Flutter SDK 不在上述路径，把命令中的 `flutter.bat` 路径换成你实际的 SDK 路径。

进入页面后的推荐操作：

1. 选择数据源模式。
2. 做现场演示时优先选择 WiFi / MQTT 实时模式。
3. 保持默认 MQTT WebSocket 配置，除非你的 Broker 地址不同。
4. 点击连接按钮，等待设备状态变为已连接。
5. 默认只展示 ECG、PPG IR、PPG RED 以及对应滤波结果，不展示 IMU 六轴。
6. 如果页面卡顿，优先关闭不必要通道，只保留 ECG 和 PPG 的关键通道。

默认 WiFi 演示策略：

- IMU 六轴不作为实时波形输出。
- ECG 原始采样和传输仍保持高采样率。
- ECG 绘图层会做显示降采样，不影响保存和传输的原始数据。
- PPG 保留实时显示。
- MQTT 高频日志默认关闭，避免浏览器控制台拖慢页面。

CSV 回放操作：

1. 切换到文件 / CSV 数据源。
2. 导入 CSV 或项目支持的历史数据文件。
3. 使用暂停、继续、时间窗口、增益、通道开关检查波形。
4. CSV 回放可以手动打开 IMU 通道查看历史数据，但 WiFi 实时演示默认不传 IMU。

BLE 模式操作：

1. 使用 Chrome 或 Edge 打开 Flutter Web。
2. 切换到 BLE 数据源。
3. 点击蓝牙连接按钮。
4. 选择设备名匹配的 ESP32 设备。
5. BLE 更适合调试和低速预览，不建议承担全通道长期高频演示。

云端上传 / 分析操作：

1. 先确认云端服务已运行在 `http://127.0.0.1:8000`。
2. 在上位机中配置或确认服务器地址。
3. 完成一次采集或导入文件后，执行上传、分析或生成报告。
4. 在管理后台查看会话、报告和告警状态。

## 管理后台

启动命令：

```powershell
cd flutter\admin_web
cmd /c npm.cmd install
cmd /c npm.cmd run dev
```

启动后 Vite 会在终端显示访问地址，通常是：

```text
http://localhost:5173
```

如果 `5173` 被占用，终端会显示新的端口，按终端提示打开即可。

使用方式：

- 先启动云端 FastAPI 服务，再打开管理后台。
- 进入后台后查看设备、采集会话、报告、任务和告警。
- 做演示时可以先准备一段已经上传的数据，在后台展示历史记录和报告结果。
- 如果页面没有数据，先检查 FastAPI 服务是否运行，以及上位机是否已经完成上传。

构建检查：

```powershell
cd flutter\admin_web
cmd /c npm.cmd run build
```

## DSP 调参网页

DSP 调参网页是独立 React / Vite 工具，主要用于离线导入 CSV、调整滤波参数、对比原始与滤波后波形，然后导出参数给固件或控制命令使用。

启动命令：

```powershell
cd flutter\dsp_debug_web
cmd /c npm.cmd install
cmd /c npm.cmd run dev
```

启动后打开终端显示的 Vite 地址，通常是：

```text
http://localhost:5173
```

如果管理后台已经占用 `5173`，Vite 会自动换到其他端口。

推荐调参流程：

1. 导入包含 ECG、PPG、IMU、时间戳的 CSV。
2. 在列映射区域选择 ECG、PPG IR、PPG RED、ax、ay、az、gx、gy、gz、timestamp 对应列。
3. 先只调 ECG：高通去基线、50Hz 陷波、低通降噪。
4. 再调 PPG：DC 去除、高频平滑、峰值是否保留。
5. 最后观察 IMU motion reference，调整 NLMS tap 数、步长、epsilon 和 motion threshold。
6. 对比原始信号、滤波信号、运动强度和质量分。
7. 导出 `dsp_params.json` 或 C++ 参数块。

调参原则：

- 演示优先时，波形稳定和观感清晰比算法复杂度更重要。
- 如果模拟前端已经做了强滤波，数字滤波参数要保守，避免 QRS 或 PPG 峰被削弱。
- ECG 默认不强行用 IMU 自适应滤波，主要用常规滤波和质量降权。
- PPG 更适合使用 IMU + NLMS 做运动伪影抑制。
- 运动过强时不要追求完全滤干净，应显示质量下降，避免波形乱跳。

构建检查：

```powershell
cd flutter\dsp_debug_web
cmd /c npm.cmd run build
```

## 常用验证命令

Flutter 静态检查：

```powershell
cd flutter\flutter_app
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" analyze
```

Flutter Web 构建：

```powershell
cd flutter\flutter_app
& "G:\课设\system\cardio-monitor-system\FlutterSDK\flutter\bin\flutter.bat" build web
```

DSP 调参网页构建：

```powershell
cd flutter\dsp_debug_web
cmd /c npm.cmd run build
```

管理后台构建：

```powershell
cd flutter\admin_web
cmd /c npm.cmd run build
```

## 演示建议

正式演示时建议这样安排：

1. 提前启动云端服务。
2. 打开 Flutter 上位机并连接 WiFi / MQTT。
3. 默认只展示 ECG、PPG IR、PPG RED 和滤波后结果。
4. 不打开 IMU 六轴实时波形。
5. 准备一份 CSV，在 WiFi 不稳定时可切换到文件回放继续展示。
6. DSP 调参网页用于展示算法可调性，不建议在实时演示主流程里频繁改参数。

如果 WiFi 模式仍然卡顿：

- 先确认浏览器控制台没有 MQTT 高频日志刷屏。
- 只保留 ECG 和一个 PPG 通道可见。
- 暂停管理后台自动刷新或先关闭管理后台页面。
- 确认 WiFi 实时链路没有发送 IMU 六轴波形。
- 优先观察 MQTT 接收速率、解析失败、seq 缺口和浏览器 CPU 占用。

## 常见问题

### 端口被占用

FastAPI 默认使用 `8000`，Vite 默认使用 `5173`。如果端口被占用，Vite 通常会自动换端口；FastAPI 则可以手动换端口：

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8001
```

换端口后，上位机和管理后台中的服务器地址也要同步修改。

### npm install 很慢或失败

确认已经安装 Node.js 和 npm。依赖安装成功后，后续通常只需要运行 `cmd /c npm.cmd run dev`。

### Flutter 命令找不到

使用完整路径调用 `flutter.bat`。如果你移动了 Flutter SDK，需要同步改命令里的路径。

### 上位机连不上云端

先在浏览器打开：

```text
http://127.0.0.1:8000/docs
```

如果打不开，说明 FastAPI 服务没有启动成功。先修复服务，再回到上位机。

### WiFi 实时模式比 CSV 卡很多

这通常说明瓶颈在通信进入量、MQTT 解析、浏览器主线程处理或可见通道过多。演示时优先采用 WiFi 演示模式：只传 ECG / PPG，不传 IMU 六轴；绘图只显示关键通道；服务器不作为实时绘图中继。

