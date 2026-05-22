from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Protocol
from urllib import error, request

from .config import Settings
from .models import ModelTrace, PatientProfile, ReportFinding, SessionRecord


@dataclass
class ProviderOutput:
    summaryAppendix: str = ''
    findings: list[ReportFinding] | None = None
    recommendations: list[str] | None = None
    riskLevel: str | None = None
    confidence: float | None = None
    modelTrace: ModelTrace | None = None


class AnalysisProvider(Protocol):
    def analyze(
        self,
        *,
        session: SessionRecord,
        features: dict[str, Any],
        excerpts: dict[str, Any],
        context: dict[str, Any],
        patient_profile: PatientProfile | None = None,
    ) -> ProviderOutput:
        ...


class ClosedSourceProvider:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def analyze(
        self,
        *,
        session: SessionRecord,
        features: dict[str, Any],
        excerpts: dict[str, Any],
        context: dict[str, Any],
        patient_profile: PatientProfile | None = None,
    ) -> ProviderOutput:
        if not (self.settings.llm_api_base_url and self.settings.llm_api_key and self.settings.llm_model):
            return ProviderOutput(
                summaryAppendix='未启用大模型，降级输出。当前报告由内置规则引擎生成，仅供参考。',
                recommendations=['如需接入大模型分析，请在服务端配置 CARDIO_LLM_API_BASE_URL、CARDIO_LLM_API_KEY 和 CARDIO_LLM_MODEL。'],
                modelTrace=ModelTrace(
                    provider='closed_source',
                    route='closed_source',
                    status='not_configured',
                    model=self.settings.llm_model or None,
                    promptVersion=self.settings.llm_prompt_version,
                    note='未检测到闭源模型配置，自动跳过外部推理。',
                ),
            )

        system_prompt = _build_system_prompt(patient_profile)
        user_content = _build_user_content(session, features, excerpts, context)

        body = {
            'model': self.settings.llm_model,
            'messages': [
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': user_content},
            ],
            'temperature': 0.2,
            'response_format': {'type': 'json_object'},
        }
        endpoint = self.settings.llm_api_base_url.rstrip('/') + '/chat/completions'
        req = request.Request(
            endpoint,
            data=json.dumps(body, ensure_ascii=False).encode('utf-8'),
            headers={
                'Content-Type': 'application/json',
                'Authorization': f'Bearer {self.settings.llm_api_key}',
            },
            method='POST',
        )
        try:
            with request.urlopen(req, timeout=60) as response:
                payload = json.loads(response.read().decode('utf-8'))
        except error.URLError as exc:
            return ProviderOutput(
                summaryAppendix='大模型调用失败，已回退到规则分析结果。',
                recommendations=['检查云端模型 API 地址、密钥和网络连通性后再次尝试。'],
                modelTrace=ModelTrace(
                    provider='closed_source',
                    route='closed_source',
                    status='error',
                    model=self.settings.llm_model,
                    promptVersion=self.settings.llm_prompt_version,
                    note=str(exc),
                ),
            )

        return _parse_openai_compatible_response(
            payload=payload,
            provider='closed_source',
            route='closed_source',
            model=self.settings.llm_model,
            prompt_version=self.settings.llm_prompt_version,
        )


class OpenSourceProvider:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def analyze(
        self,
        *,
        session: SessionRecord,
        features: dict[str, Any],
        excerpts: dict[str, Any],
        context: dict[str, Any],
        patient_profile: PatientProfile | None = None,
    ) -> ProviderOutput:
        if not (self.settings.local_llm_base_url and self.settings.local_llm_model):
            return ProviderOutput(
                summaryAppendix='开源自部署模型接口已预留，但当前未配置。',
                recommendations=['后续接入本地模型服务时，只需补充本地模型地址与模型名。'],
                modelTrace=ModelTrace(
                    provider='open_source',
                    route='open_source',
                    status='not_configured',
                    model=self.settings.local_llm_model or None,
                    promptVersion='v1',
                    note='保留接口，暂不执行本地模型推理。',
                ),
            )

        system_prompt = _build_system_prompt(patient_profile)
        user_content = _build_user_content(session, features, excerpts, context)

        body = {
            'model': self.settings.local_llm_model,
            'messages': [
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': user_content},
            ],
            'temperature': 0.2,
        }
        endpoint = self.settings.local_llm_base_url.rstrip('/') + '/chat/completions'
        req = request.Request(
            endpoint,
            data=json.dumps(body, ensure_ascii=False).encode('utf-8'),
            headers={'Content-Type': 'application/json'},
            method='POST',
        )
        try:
            with request.urlopen(req, timeout=120) as response:
                payload = json.loads(response.read().decode('utf-8'))
        except error.URLError as exc:
            return ProviderOutput(
                summaryAppendix='开源模型调用失败，已保留规则分析结果。',
                recommendations=['检查本地推理服务是否启动，并确认服务器算力与模型镜像可用。'],
                modelTrace=ModelTrace(
                    provider='open_source',
                    route='open_source',
                    status='error',
                    model=self.settings.local_llm_model,
                    promptVersion='v1',
                    note=str(exc),
                ),
            )

        return _parse_openai_compatible_response(
            payload=payload,
            provider='open_source',
            route='open_source',
            model=self.settings.local_llm_model,
            prompt_version='v1',
        )


def build_analysis_provider(settings: Settings) -> AnalysisProvider:
    if settings.analysis_provider_route == 'open_source':
        return OpenSourceProvider(settings)
    return ClosedSourceProvider(settings)


def _build_system_prompt(patient_profile: PatientProfile | None) -> str:
    profile_section = ''
    if patient_profile:
        parts = []
        if patient_profile.age is not None:
            parts.append(f'年龄：{patient_profile.age} 岁')
        if patient_profile.gender:
            parts.append(f'性别：{patient_profile.gender}')
        if patient_profile.medicalHistory:
            parts.append(f'既往病史：{patient_profile.medicalHistory}')
        if parts:
            profile_section = (
                '\n\n## 患者档案\n'
                + '\n'.join(parts)
                + '\n请结合上述患者信息进行分析。如有既往病史，请在分析中适当关联；如无病史信息，则按正常人标准进行评估。'
            )

    return (
        '你是一名专业的心肺监测报告辅助分析助手。你的任务是根据提供的生理信号监测数据，'
        '生成一份结构化的辅助分析报告。\n\n'
        '## 重要说明\n'
        '- 本报告仅供临床参考，不构成医疗诊断结论。\n'
        '- 描述应客观、审慎，避免过于笃定的诊断性语言。\n'
        '- 风险等级和置信度应基于数据质量和信号特征综合判断，不应夸大。\n\n'
        '## 分析维度\n'
        '请依次分析以下维度（如数据缺失则跳过该维度）：\n'
        '1. **心率与心律**：平均心率是否在正常范围（60-100 bpm），是否存在明显异常节律迹象。\n'
        '2. **心率变异性（HRV）**：RMSSD、SDNN、pNN50 的参考意义，是否提示自主神经功能异常。\n'
        '3. **呼吸频率**：估算值是否在正常范围（12-20 次/分），是否存在异常。\n'
        '4. **血氧饱和度（SpO2）**：估算值是否在正常范围（≥95%），是否存在低氧风险。\n'
        '5. **体温**：是否在正常范围（36.0-37.5°C），是否存在发热或低体温迹象。\n'
        '6. **信号质量**：整体质量评分和各通道质量，是否影响分析可信度。\n'
        '7. **综合风险评估**：综合以上维度，给出整体风险等级。\n\n'
        '## 输出格式\n'
        '必须返回合法 JSON，包含以下字段：\n'
        '```json\n'
        '{\n'
        '  "summaryAppendix": "对本次监测数据的综合文字描述（2-4句话，客观审慎）",\n'
        '  "riskLevel": "low | medium | high",\n'
        '  "confidence": 0.0到1.0之间的浮点数（反映分析可信度，受数据质量和时长影响）,\n'
        '  "findings": [\n'
        '    {\n'
        '      "title": "发现标题（简短）",\n'
        '      "severity": "info | low | medium | high",\n'
        '      "detail": "具体描述（1-2句话，客观，不做确定性诊断）"\n'
        '    }\n'
        '  ],\n'
        '  "recommendations": [\n'
        '    "建议条目1",\n'
        '    "建议条目2"\n'
        '  ]\n'
        '}\n'
        '```\n\n'
        '## 风险等级参考标准\n'
        '- **low**：各项指标基本正常，信号质量良好，无明显异常迹象。\n'
        '- **medium**：存在部分指标偏离正常范围，或信号质量较差导致分析不确定性较高，建议关注。\n'
        '- **high**：存在明显异常指标（如心率极度异常、SpO2 显著偏低、HRV 极度异常等），建议及时就医。\n\n'
        '## 置信度参考标准\n'
        '- 监测时长 ≥ 30s 且信号质量 ≥ 0.8：置信度可达 0.8 以上。\n'
        '- 监测时长 10-30s 或信号质量 0.6-0.8：置信度约 0.5-0.75。\n'
        '- 监测时长 < 10s 或信号质量 < 0.6：置信度低于 0.5，分析结果仅供参考。'
        + profile_section
    )


def _build_user_content(
    session: SessionRecord,
    features: dict[str, Any],
    excerpts: dict[str, Any],
    context: dict[str, Any],
) -> str:
    physio = (features.get('metrics') or {}).get('physiologicalMetrics') or {}
    channels = features.get('channels') or {}
    duration = features.get('durationSeconds', 0)
    quality = features.get('qualityScore', 0)

    channel_summaries = []
    for key, ch in channels.items():
        if isinstance(ch, dict):
            channel_summaries.append({
                'channel': key,
                'mean': ch.get('mean'),
                'min': ch.get('min'),
                'max': ch.get('max'),
                'rms': ch.get('rms'),
                'meanQuality': ch.get('meanQuality'),
                'sampleCount': ch.get('sampleCount'),
            })

    data = {
        'sessionId': session.id,
        'deviceId': session.deviceId,
        'durationSeconds': duration,
        'qualityScore': quality,
        'channelCount': len(channels),
        'channelSummaries': channel_summaries,
        'physiologicalMetrics': physio,
        'ruleAnalysis': context.get('ruleReport', {}),
        'analysisScope': context.get('analysisScope', 'session'),
    }
    return json.dumps(data, ensure_ascii=False)


def _parse_openai_compatible_response(
    *,
    payload: dict[str, Any],
    provider: str,
    route: str,
    model: str,
    prompt_version: str,
) -> ProviderOutput:
    message = ''
    choices = payload.get('choices') or []
    if choices:
        message = choices[0].get('message', {}).get('content', '') or ''

    parsed: dict[str, Any]
    try:
        parsed = json.loads(message) if message else {}
    except json.JSONDecodeError:
        parsed = {'summaryAppendix': message}

    findings = []
    for item in parsed.get('findings', []) or []:
        try:
            findings.append(ReportFinding(**item))
        except TypeError:
            continue

    return ProviderOutput(
        summaryAppendix=str(parsed.get('summaryAppendix', '') or ''),
        findings=findings,
        recommendations=[str(item) for item in (parsed.get('recommendations') or [])],
        riskLevel=str(parsed['riskLevel']) if parsed.get('riskLevel') in ('low', 'medium', 'high') else None,
        confidence=float(parsed.get('confidence')) if parsed.get('confidence') is not None else None,
        modelTrace=ModelTrace(
            provider=provider,
            route=route,
            status='completed',
            model=model,
            promptVersion=prompt_version,
            note='模型推理完成。',
        ),
    )
