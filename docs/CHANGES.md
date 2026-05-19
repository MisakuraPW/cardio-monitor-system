# 功能改动说明

> 本文档记录本次开发周期内对 `cardio-monitor-system` 所做的全部改动，按模块分类说明。

---

## 一、Flutter 上位机 — 温度接收与显示

### 改动文件
- `flutter/flutter_app/lib/src/data_sources.dart`
- `flutter/flutter_app/lib/src/dashboard_page.dart`

### 内容
ESP32 固件已通过两条 MQTT 主题发送温度数据：
- `cardio/{device}/temperature`：JSON 格式，含 `samples[].tempC`
- `cardio/{device}/waveform_bin/temp`：BIO2 二进制帧，类型字节 `'T'`

上位机新增对这两条主题的订阅与解析：

1. **BIO2 二进制解码**：在 `_Bio1BinaryCodec.decode()` 中新增 `case 'T':`，调用 `_decodeTemp()` 方法。每个样本结构为 `8B ts_us + 2B raw + 4B float32 temp_c + 1B flags = 15B`，解码后生成 `channelKey='temp'` 的 `SignalFrame`。

2. **JSON 解码**：新增 `_handleTemperatureJson()` 方法，解析 `/temperature` 主题的 JSON 消息，提取 `tempC` 和 `tsUs` 字段，生成同样的 `SignalFrame`。

3. **显示**：温度不以波形形式展示，而是在"本地统计与分析"面板的"生理参数估算"区域以数值 chip 形式显示（单位 °C）。

---

## 二、Flutter 上位机 — 本地统计与分析增强

### 改动文件
- `flutter/flutter_app/lib/src/models.dart`
- `flutter/flutter_app/lib/src/monitor_controller.dart`
- `flutter/flutter_app/lib/src/dashboard_page.dart`

### 内容

#### 新增 `PhysiologicalMetrics` 模型（`models.dart`）
包含以下字段（均为可选）：
- `heartRateBpm`：平均心率（bpm）
- `hrvRmssd`：HRV RMSSD（ms）
- `hrvSdnn`：HRV SDNN（ms）
- `hrvPnn50`：HRV pNN50（%）
- `respiratoryRateBpm`：呼吸频率（次/分）
- `spo2Percent`：血氧饱和度估算（%）
- `temperatureCelsius`：体温（°C）
- `notes`：分析备注列表

`LocalAnalysisSnapshot` 新增 `physio` 字段（类型 `PhysiologicalMetrics`）。

#### 生理参数计算（`monitor_controller.dart`）

新增 `_computePhysio()` 方法，在每次刷新本地分析时调用，包含：

- **心率 & HRV**：从 `ecg_filtered`（或 `ecg`）缓冲区取样，通过 `_detectRRIntervals()` 检测 R 峰（阈值 = 均值 + 0.6×标准差，最小峰间距 300ms），计算：
  - 平均心率 = 60000 / 平均RR
  - SDNN = RR 间期标准差
  - RMSSD = 相邻RR差值均方根
  - pNN50 = 相邻RR差值 > 50ms 的比例

- **呼吸频率**：从 PPG 缓冲区取样，降采样至约 4Hz，对移动平均基线做零交叉计数，换算为次/分（有效范围 4–40）。

- **SpO2 估算**：从 IR 和 Red PPG 通道各取 AC/DC 分量，计算 R = (redAC/redDC)/(irAC/irDC)，SpO2 ≈ 110 − 25×R（经验校准曲线，结果限定在 70–100%）。

- **体温**：直接取 `temp` 通道缓冲区的均值。

#### 分段上传指标（`monitor_controller.dart`）
`_buildSegmentMetrics()` 新增 `'physiologicalMetrics': snapshot.physio.toJson()`，随分段数据一并上传至云端，供大模型分析使用。

#### 界面展示（`dashboard_page.dart`）
"本地统计与分析"卡片新增"生理参数估算"区域，当 `physio.hasAny` 为 true 时显示各项指标 chip（心率、HRV RMSSD/SDNN/pNN50、呼吸频率、SpO2、体温）。

---

## 三、云端服务 — 大模型接入完善

### 改动文件
- `flutter/cloud_server/app/models.py`
- `flutter/cloud_server/app/analysis_provider.py`
- `flutter/cloud_server/app/analysis_service.py`
- `flutter/cloud_server/app/storage.py`
- `flutter/cloud_server/app/main.py`

### 3.1 数据模型（`models.py`）

- 新增 `PatientProfile` 模型：`age`（可选整数）、`gender`（可选字符串）、`medicalHistory`（可选字符串）。
- `MedicalReport` 新增 `riskLevel: str | None` 字段，取值为 `'low'`、`'medium'`、`'high'` 或 `None`。
- `AnalysisJobCreate` 新增 `patientProfile: PatientProfile | None` 字段，允许在触发分析时传入患者档案。

### 3.2 分析 Provider（`analysis_provider.py`）

**System Prompt 重写**（`_build_system_prompt()`）：
- 明确说明报告仅供临床参考，不构成诊断结论。
- 列出 7 个分析维度：心率与心律、HRV、呼吸频率、SpO2、体温、信号质量、综合风险评估。
- 规定输出为合法 JSON，字段包含 `summaryAppendix`、`riskLevel`、`confidence`、`findings`、`recommendations`。
- 给出风险等级（low/medium/high）和置信度的参考标准。
- 若传入 `PatientProfile`，在 prompt 末尾追加患者档案段落，指示模型结合病史分析；无病史则按正常人标准评估。

**用户消息构建**（`_build_user_content()`）：
- 发送结构化 JSON，包含：sessionId、deviceId、监测时长、质量评分、各通道摘要统计、生理参数估算（来自 `metrics.physiologicalMetrics`）、规则分析结果。

**其他改动**：
- `ProviderOutput` 新增 `riskLevel` 字段。
- `_parse_openai_compatible_response()` 从模型输出中提取 `riskLevel`（仅接受 `low/medium/high`）。
- 未配置 API 时的 fallback 消息改为"未启用大模型，降级输出"。
- `ClosedSourceProvider` 请求超时从 25s 延长至 60s；`OpenSourceProvider` 从 45s 延长至 120s。
- 两个 Provider 均新增 `patient_profile` 参数。

### 3.3 分析服务（`analysis_service.py`）

- `process_analysis_job()` 和 `process_segment_analysis()` 新增 `patient_profile` 参数，并传递给 Provider。
- `_merge_reports()` 新增 `risk_level` 参数，优先使用模型输出的风险等级，回退到规则报告的值。

### 3.4 数据库迁移（`storage.py`）

- `reports` 表通过 `_ensure_column()` 自动添加 `risk_level TEXT` 列（兼容已有数据库，无需手动迁移）。
- `save_report()` 持久化 `riskLevel`。
- `_row_to_report()` 读取 `risk_level` 列。
- 新增 `get_latest_report()` 方法，返回最近生成的一条报告（供 LLM 配置页面展示）。

### 3.5 LLM 配置管理页面（`main.py`）

新增路由 `/llm-config`，提供一个纯 HTML 管理界面，包含：

1. **当前配置状态**：显示 API Base URL、模型名、API Key 是否已设置、Prompt 版本，以及配置环境变量的说明。

2. **连接测试**：填入临时 API Base URL、API Key、模型名，点击"测试连接"按钮，调用 `POST /api/v1/llm/test` 端点，向模型发送一条简单测试消息，显示连接是否成功及模型响应。不会修改服务器配置。

3. **System Prompt 与输出格式**（Tab 切换）：
   - **System Prompt**：展示当前实际使用的完整 prompt 文本。
   - **输出格式要求**：展示期望模型返回的 JSON Schema 示例。
   - **最近一条报告**：从 `GET /api/v1/llm/config` 动态加载，展示最近一次生成的完整报告 JSON。

新增 API 端点：
- `GET /api/v1/llm/config`：返回配置状态、prompt 文本、输出 schema、最近报告。
- `POST /api/v1/llm/test`：接受 `{apiBaseUrl, apiKey, model}`，发起连接测试，返回 `{success, model, response}` 或 `{success, error}`。

首页 `/` 新增 `/llm-config` 入口链接。

---

## 四、Flutter 上位机 — 云端报告展示增强

### 改动文件
- `flutter/flutter_app/lib/src/models.dart`
- `flutter/flutter_app/lib/src/dashboard_page.dart`

### 内容

- `MedicalReport.fromJson()` 新增解析 `riskLevel`（字符串）和 `confidence`（浮点数）字段。
- `_ReportCard` 组件重写：
  - 标题行右侧显示彩色风险等级徽章（低风险绿色、中风险橙色、高风险红色）。
  - 显示分析置信度百分比。
  - 当报告摘要包含"未启用大模型"时，显示黄色"未启用大模型，降级输出"提示条。
  - 每条 finding 左侧显示彩色圆点（按 severity 着色），替代原来的 `[severity]` 文字。

---

## 五、配置说明

大模型接入通过以下环境变量配置（在服务端 `.env` 文件中设置）：

| 变量名 | 说明 | 示例值 |
|--------|------|--------|
| `CARDIO_LLM_API_BASE_URL` | OpenAI 兼容 API 地址 | `https://api.deepseek.com/v1` |
| `CARDIO_LLM_API_KEY` | API 密钥 | `sk-...` |
| `CARDIO_LLM_MODEL` | 模型名称 | `deepseek-chat` |
| `CARDIO_LLM_PROMPT_VERSION` | Prompt 版本标记（可选） | `v2` |

三个变量均配置后，大模型分析自动启用；任一缺失则降级为规则引擎输出，报告中显示"未启用大模型，降级输出"提示。

患者档案（年龄、性别、既往病史）可在触发分析时通过 `POST /api/v1/analysis/jobs` 的请求体传入：

```json
{
  "sessionId": "session-xxx",
  "patientProfile": {
    "age": 45,
    "gender": "男",
    "medicalHistory": "高血压病史3年，长期服用降压药"
  }
}
```
