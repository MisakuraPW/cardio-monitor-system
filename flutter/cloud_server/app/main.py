from __future__ import annotations

import csv
import json
from io import StringIO

from fastapi import FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel

from .analysis_provider import _build_system_prompt
from .analysis_service import process_analysis_job, process_segment_analysis
from .config import Settings, settings
from .models import (
    AdminOverview,
    AdminSessionItem,
    AlertCreate,
    AlertRecord,
    AnalysisJobCreate,
    AnalysisJobRecord,
    ChannelCatalogCreate,
    ChannelCatalogRecord,
    DeviceRecord,
    DeviceUpsert,
    FrameBatchIngest,
    IngestSessionOpen,
    MedicalReport,
    PatientProfile,
    RawChunkRecord,
    SegmentAnalysisResult,
    SegmentDetail,
    SegmentRecord,
    SegmentUploadCreate,
    SessionCreate,
    SessionDetail,
    SessionRecord,
    UploadCreate,
    UploadRecord,
    UserRecord,
)
from .storage import SQLiteStorage

storage = SQLiteStorage()
app = FastAPI(title='Cardio Cloud Service', version='0.2.0')

app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_credentials=True,
    allow_methods=['*'],
    allow_headers=['*'],
)


@app.get('/', response_class=HTMLResponse)
def index() -> str:
    return '''
    <html>
      <head>
        <meta charset="utf-8" />
        <title>Cardio Cloud Service</title>
        <style>
          body { font-family: Arial, sans-serif; margin: 40px; background: #f5f8f6; color: #1f2933; }
          .card { background: white; border: 1px solid #d8e2dc; border-radius: 16px; padding: 24px; max-width: 840px; }
          a { color: #0b6e4f; }
          code { background: #f0f4f8; padding: 2px 6px; border-radius: 6px; }
          li { margin-bottom: 8px; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Cardio Cloud Service</h1>
          <p>云端已经启动成功。当前服务包含 API、管理查询接口、MQTT 接入预留和分析 Provider 抽象。</p>
          <ul>
            <li>打开 <a href="/docs" target="_blank">/docs</a> 查看 Swagger 接口文档</li>
            <li>访问 <a href="/api/v1/health" target="_blank">/api/v1/health</a> 检查服务存活</li>
            <li>访问 <a href="/llm-config" target="_blank">/llm-config</a> 配置大模型 API 并查看 Prompt</li>
            <li>上位机上传沿用 <code>POST /api/v1/sessions</code> 和 <code>/uploads</code></li>
            <li>设备直传可使用 <code>/api/v1/ingest/mqtt/*</code> 接口或独立 MQTT ingest 服务</li>
          </ul>
          <p>管理后台建议单独运行 <code>admin_web</code>，并通过 <code>X-Admin-Token</code> 访问 admin 接口。</p>
        </div>
      </body>
    </html>
    '''


@app.get('/api/v1/health')
def health() -> dict[str, str]:
    return {
        'status': 'ok',
        'env': settings.app_env,
        'analysisExecutionMode': settings.analysis_execution_mode,
    }


# ---------------------------------------------------------------------------
# LLM 配置管理页面
# ---------------------------------------------------------------------------

class LlmTestRequest(BaseModel):
    apiBaseUrl: str
    apiKey: str
    model: str
    patientProfile: PatientProfile | None = None


@app.get('/llm-config', response_class=HTMLResponse)
def llm_config_page() -> str:
    return _render_llm_config_page()


@app.get('/api/v1/llm/config')
def get_llm_config() -> dict:
    configured = bool(settings.llm_api_base_url and settings.llm_api_key and settings.llm_model)
    prompt = _build_system_prompt(None)
    output_schema = {
        'summaryAppendix': '对本次监测数据的综合文字描述（2-4句话，客观审慎）',
        'riskLevel': 'low | medium | high',
        'confidence': '0.0 ~ 1.0 浮点数，反映分析可信度',
        'findings': [
            {
                'title': '发现标题（简短）',
                'severity': 'info | low | medium | high',
                'detail': '具体描述（1-2句话，客观，不做确定性诊断）',
            }
        ],
        'recommendations': ['建议条目1', '建议条目2'],
    }
    latest_report = storage.get_latest_report()
    return {
        'configured': configured,
        'apiBaseUrl': settings.llm_api_base_url or '',
        'model': settings.llm_model or '',
        'promptVersion': settings.llm_prompt_version,
        'systemPrompt': prompt,
        'outputSchema': output_schema,
        'latestReport': latest_report.model_dump() if latest_report else None,
    }


@app.post('/api/v1/llm/test')
def test_llm_connection(payload: LlmTestRequest) -> dict:
    from urllib import error, request as urllib_request
    test_body = {
        'model': payload.model,
        'messages': [
            {'role': 'system', 'content': '请回复 {"status": "ok", "message": "连接测试成功"}'},
            {'role': 'user', 'content': '连接测试'},
        ],
        'temperature': 0,
        'max_tokens': 64,
        'response_format': {'type': 'json_object'},
    }
    endpoint = payload.apiBaseUrl.rstrip('/') + '/chat/completions'
    req = urllib_request.Request(
        endpoint,
        data=json.dumps(test_body, ensure_ascii=False).encode('utf-8'),
        headers={
            'Content-Type': 'application/json',
            'Authorization': f'Bearer {payload.apiKey}',
        },
        method='POST',
    )
    try:
        with urllib_request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read().decode('utf-8'))
        choices = result.get('choices') or []
        content = choices[0].get('message', {}).get('content', '') if choices else ''
        return {'success': True, 'model': result.get('model', payload.model), 'response': content}
    except error.HTTPError as exc:
        body = exc.read().decode('utf-8', errors='replace') if exc.fp else ''
        return {'success': False, 'error': f'HTTP {exc.code}: {body[:300]}'}
    except error.URLError as exc:
        return {'success': False, 'error': str(exc)}


def _render_llm_config_page() -> str:
    configured = bool(settings.llm_api_base_url and settings.llm_api_key and settings.llm_model)
    status_color = '#2a9d8f' if configured else '#e76f51'
    status_text = '已配置' if configured else '未配置'
    api_base = settings.llm_api_base_url or ''
    model_name = settings.llm_model or ''
    prompt_version = settings.llm_prompt_version
    prompt_text = _build_system_prompt(None)
    output_schema_json = json.dumps({
        'summaryAppendix': '对本次监测数据的综合文字描述（2-4句话，客观审慎）',
        'riskLevel': 'low | medium | high',
        'confidence': 0.75,
        'findings': [
            {'title': '发现标题', 'severity': 'info | low | medium | high', 'detail': '具体描述'},
        ],
        'recommendations': ['建议条目1', '建议条目2'],
    }, ensure_ascii=False, indent=2)

    return f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>大模型配置 — Cardio Cloud</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
           background: #f0f4f8; color: #1f2933; min-height: 100vh; padding: 32px 16px; }}
    .page {{ max-width: 900px; margin: 0 auto; display: flex; flex-direction: column; gap: 20px; }}
    h1 {{ font-size: 1.5rem; font-weight: 700; color: #1f2933; }}
    .nav {{ font-size: 0.85rem; color: #627d98; margin-bottom: 4px; }}
    .nav a {{ color: #0b6e4f; text-decoration: none; }}
    .card {{ background: #fff; border: 1px solid #d9e2ec; border-radius: 14px;
             padding: 24px; display: flex; flex-direction: column; gap: 16px; }}
    .card h2 {{ font-size: 1rem; font-weight: 600; color: #334e68; border-bottom: 1px solid #f0f4f8;
                padding-bottom: 10px; }}
    .badge {{ display: inline-block; padding: 3px 12px; border-radius: 20px; font-size: 0.8rem;
              font-weight: 600; background: {status_color}22; color: {status_color};
              border: 1px solid {status_color}; }}
    .kv {{ display: grid; grid-template-columns: 140px 1fr; gap: 6px 12px; font-size: 0.9rem; }}
    .kv .k {{ color: #627d98; font-weight: 500; }}
    .kv .v {{ color: #1f2933; word-break: break-all; }}
    label {{ font-size: 0.85rem; font-weight: 500; color: #486581; display: block; margin-bottom: 4px; }}
    input {{ width: 100%; padding: 8px 12px; border: 1px solid #bcccdc; border-radius: 8px;
             font-size: 0.9rem; outline: none; transition: border 0.15s; }}
    input:focus {{ border-color: #0b6e4f; }}
    .row {{ display: flex; gap: 12px; }}
    .row input {{ flex: 1; }}
    button {{ padding: 9px 22px; border: none; border-radius: 8px; font-size: 0.9rem;
              font-weight: 600; cursor: pointer; transition: opacity 0.15s; }}
    button:hover {{ opacity: 0.85; }}
    .btn-primary {{ background: #0b6e4f; color: #fff; }}
    .btn-secondary {{ background: #f0f4f8; color: #334e68; border: 1px solid #bcccdc; }}
    #test-result {{ font-size: 0.85rem; padding: 10px 14px; border-radius: 8px;
                    display: none; white-space: pre-wrap; word-break: break-all; }}
    .ok  {{ background: #e6f4f1; color: #0b6e4f; border: 1px solid #a8d5c9; }}
    .err {{ background: #fdecea; color: #c0392b; border: 1px solid #f5c6c2; }}
    pre {{ background: #f8fafc; border: 1px solid #d9e2ec; border-radius: 10px;
           padding: 16px; font-size: 0.8rem; line-height: 1.6; overflow-x: auto;
           white-space: pre-wrap; word-break: break-word; max-height: 420px; overflow-y: auto; }}
    .tabs {{ display: flex; gap: 4px; }}
    .tab {{ padding: 6px 16px; border-radius: 8px 8px 0 0; font-size: 0.85rem; font-weight: 500;
             cursor: pointer; border: 1px solid #d9e2ec; border-bottom: none;
             background: #f0f4f8; color: #627d98; }}
    .tab.active {{ background: #fff; color: #0b6e4f; border-color: #d9e2ec; }}
    .tab-panel {{ display: none; }}
    .tab-panel.active {{ display: block; }}
    #report-out {{ display: none; }}
    .spinner {{ display: inline-block; width: 14px; height: 14px; border: 2px solid #fff;
                border-top-color: transparent; border-radius: 50%; animation: spin 0.7s linear infinite; }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  </style>
</head>
<body>
<div class="page">
  <div>
    <div class="nav"><a href="/">← 首页</a> / 大模型配置</div>
    <h1>大模型配置与调试</h1>
  </div>

  <!-- 当前配置状态 -->
  <div class="card">
    <h2>当前配置状态</h2>
    <div style="display:flex;align-items:center;gap:10px">
      <span class="badge">{status_text}</span>
      <span style="font-size:0.85rem;color:#627d98">通过环境变量配置，修改后需重启服务</span>
    </div>
    <div class="kv">
      <span class="k">API Base URL</span>
      <span class="v">{api_base or '<em style="color:#9aa5b4">未设置 CARDIO_LLM_API_BASE_URL</em>'}</span>
      <span class="k">模型</span>
      <span class="v">{model_name or '<em style="color:#9aa5b4">未设置 CARDIO_LLM_MODEL</em>'}</span>
      <span class="k">API Key</span>
      <span class="v">{'已设置（已隐藏）' if settings.llm_api_key else '<em style="color:#9aa5b4">未设置 CARDIO_LLM_API_KEY</em>'}</span>
      <span class="k">Prompt 版本</span>
      <span class="v">{prompt_version}</span>
    </div>
    <div style="font-size:0.82rem;color:#9aa5b4;background:#f8fafc;border-radius:8px;padding:10px 14px">
      在服务器 <code>.env</code> 文件中设置以下变量后重启：<br>
      <code>CARDIO_LLM_API_BASE_URL=https://api.deepseek.com/v1</code><br>
      <code>CARDIO_LLM_API_KEY=sk-...</code><br>
      <code>CARDIO_LLM_MODEL=deepseek-chat</code>
    </div>
  </div>

  <!-- 连接测试 -->
  <div class="card">
    <h2>连接测试</h2>
    <p style="font-size:0.85rem;color:#627d98">临时填入参数测试连通性，不会修改服务器配置。</p>
    <div>
      <label>API Base URL</label>
      <input id="t-url" type="text" placeholder="https://api.deepseek.com/v1" value="{api_base}" />
    </div>
    <div class="row">
      <div style="flex:1">
        <label>API Key</label>
        <input id="t-key" type="password" placeholder="sk-..." />
      </div>
      <div style="flex:1">
        <label>模型名</label>
        <input id="t-model" type="text" placeholder="deepseek-chat" value="{model_name}" />
      </div>
    </div>
    <div style="display:flex;gap:10px;align-items:center">
      <button class="btn-primary" onclick="testConn()">
        <span id="test-btn-text">测试连接</span>
      </button>
    </div>
    <div id="test-result"></div>
  </div>

  <!-- Prompt 与输出格式 -->
  <div class="card">
    <h2>System Prompt 与输出格式</h2>
    <div class="tabs">
      <div class="tab active" onclick="switchTab('prompt')">System Prompt</div>
      <div class="tab" onclick="switchTab('schema')">输出格式要求</div>
      <div class="tab" onclick="switchTab('report')">最近一条报告</div>
    </div>
    <div id="tab-prompt" class="tab-panel active">
      <pre id="prompt-pre">{prompt_text}</pre>
    </div>
    <div id="tab-schema" class="tab-panel">
      <pre>{output_schema_json}</pre>
    </div>
    <div id="tab-report" class="tab-panel">
      <div id="report-loading" style="font-size:0.85rem;color:#9aa5b4">加载中...</div>
      <pre id="report-pre" style="display:none"></pre>
      <div id="report-empty" style="display:none;font-size:0.85rem;color:#9aa5b4">暂无报告记录。</div>
    </div>
  </div>
</div>

<script>
function switchTab(name) {{
  document.querySelectorAll('.tab').forEach((t, i) => {{
    const names = ['prompt', 'schema', 'report'];
    t.classList.toggle('active', names[i] === name);
  }});
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  if (name === 'report') loadReport();
}}

function loadReport() {{
  const pre = document.getElementById('report-pre');
  const loading = document.getElementById('report-loading');
  const empty = document.getElementById('report-empty');
  if (pre.style.display !== 'none' || empty.style.display !== 'none') return;
  fetch('/api/v1/llm/config')
    .then(r => r.json())
    .then(d => {{
      loading.style.display = 'none';
      if (d.latestReport) {{
        pre.textContent = JSON.stringify(d.latestReport, null, 2);
        pre.style.display = 'block';
      }} else {{
        empty.style.display = 'block';
      }}
    }})
    .catch(() => {{ loading.textContent = '加载失败'; }});
}}

function testConn() {{
  const url = document.getElementById('t-url').value.trim();
  const key = document.getElementById('t-key').value.trim();
  const model = document.getElementById('t-model').value.trim();
  const result = document.getElementById('test-result');
  const btnText = document.getElementById('test-btn-text');
  if (!url || !key || !model) {{
    result.className = 'err';
    result.textContent = '请填写 API Base URL、API Key 和模型名。';
    result.style.display = 'block';
    return;
  }}
  btnText.innerHTML = '<span class="spinner"></span> 测试中...';
  result.style.display = 'none';
  fetch('/api/v1/llm/test', {{
    method: 'POST',
    headers: {{'Content-Type': 'application/json'}},
    body: JSON.stringify({{apiBaseUrl: url, apiKey: key, model: model}})
  }})
  .then(r => r.json())
  .then(d => {{
    btnText.textContent = '测试连接';
    if (d.success) {{
      result.className = 'ok';
      result.textContent = '✓ 连接成功\\n模型：' + d.model + '\\n响应：' + d.response;
    }} else {{
      result.className = 'err';
      result.textContent = '✗ 连接失败\\n' + d.error;
    }}
    result.style.display = 'block';
  }})
  .catch(e => {{
    btnText.textContent = '测试连接';
    result.className = 'err';
    result.textContent = '请求异常：' + e;
    result.style.display = 'block';
  }});
}}
</script>
</body>
</html>'''


@app.post('/api/v1/sessions', response_model=SessionRecord)
def create_session(payload: SessionCreate) -> SessionRecord:
    return storage.create_session(payload)


@app.get('/api/v1/sessions/{session_id}', response_model=SessionDetail)
def get_session(session_id: str) -> SessionDetail:
    try:
        return storage.get_session_detail(session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Session not found') from exc


@app.get('/api/v1/sessions/{session_id}/raw', response_model=list[RawChunkRecord])
def get_session_raw(session_id: str) -> list[RawChunkRecord]:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.list_raw_chunks(session_id)


@app.post('/api/v1/sessions/{session_id}/uploads', response_model=UploadRecord)
def create_upload(session_id: str, payload: UploadCreate) -> UploadRecord:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.create_upload(session_id, payload)


@app.post('/api/v1/sessions/{session_id}/segments', response_model=SegmentRecord)
def create_segment(session_id: str, payload: SegmentUploadCreate) -> SegmentRecord:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    if payload.sessionId != session_id:
        raise HTTPException(status_code=400, detail='Segment sessionId does not match path')
    return storage.create_segment(session_id, payload)


@app.get('/api/v1/sessions/{session_id}/segments', response_model=list[SegmentRecord])
def list_session_segments(session_id: str) -> list[SegmentRecord]:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.list_segments(session_id)


@app.get('/api/v1/sessions/{session_id}/segments/{segment_id}', response_model=SegmentDetail)
def get_session_segment(session_id: str, segment_id: str) -> SegmentDetail:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    try:
        return storage.get_segment_detail(session_id, segment_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Segment not found') from exc


@app.get('/api/v1/sessions/{session_id}/segments/{segment_id}/csv')
def download_session_segment_csv(session_id: str, segment_id: str) -> StreamingResponse:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    try:
        segment = storage.get_segment_detail(session_id, segment_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Segment not found') from exc
    filename = f'{segment.userName}_segment_{segment.segmentIndex}.csv'.replace(' ', '_')
    return StreamingResponse(
        iter([_segment_to_csv(segment)]),
        media_type='text/csv; charset=utf-8',
        headers={'Content-Disposition': f'attachment; filename="{filename}"'},
    )


@app.post('/api/v1/sessions/{session_id}/segments/{segment_id}/analyze', response_model=SegmentAnalysisResult)
def analyze_session_segment(
    session_id: str,
    segment_id: str,
    payload: AnalysisJobCreate | None = None,
) -> SegmentAnalysisResult:
    if storage.get_session(session_id) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    patient_profile = payload.patientProfile if payload else None
    try:
        report = process_segment_analysis(storage, settings, session_id, segment_id, patient_profile=patient_profile)
        segment = storage.get_segment_detail(session_id, segment_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Segment not found') from exc
    return SegmentAnalysisResult(segment=segment, report=report)


@app.get('/api/v1/sessions/{session_id}/segments/{segment_id}/report', response_model=MedicalReport)
def get_session_segment_report(session_id: str, segment_id: str) -> MedicalReport:
    report = storage.get_segment_report(session_id, segment_id)
    if report is None:
        raise HTTPException(status_code=404, detail='Segment report not found')
    return report


@app.get('/api/v1/users', response_model=list[UserRecord])
def list_users() -> list[UserRecord]:
    return storage.list_users()


@app.get('/api/v1/users/{user_id}/sessions', response_model=list[SessionRecord])
def list_user_sessions(user_id: str) -> list[SessionRecord]:
    return storage.list_sessions_for_user(user_id)


@app.post('/api/v1/analysis/jobs', response_model=AnalysisJobRecord)
def create_analysis_job(payload: AnalysisJobCreate) -> AnalysisJobRecord:
    if storage.get_session(payload.sessionId) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    if storage.get_latest_upload_payload(payload.sessionId) is None:
        raise HTTPException(status_code=400, detail='Upload payload not found')

    job = storage.create_analysis_job(payload)
    if settings.analysis_execution_mode == 'inline':
        process_analysis_job(storage, settings, job.id, patient_profile=payload.patientProfile)
        return storage.get_analysis_job(job.id)
    return job


@app.get('/api/v1/analysis/jobs/{job_id}', response_model=AnalysisJobRecord)
def get_analysis_job(job_id: str) -> AnalysisJobRecord:
    try:
        return storage.get_analysis_job(job_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Analysis job not found') from exc


@app.get('/api/v1/reports/{session_id}', response_model=MedicalReport)
def get_report(session_id: str) -> MedicalReport:
    report = storage.get_report(session_id)
    if report is None:
        raise HTTPException(status_code=404, detail='Report not found')
    return report


@app.post('/api/v1/ingest/mqtt/session/open', response_model=SessionRecord)
def open_ingest_session(payload: IngestSessionOpen) -> SessionRecord:
    record = storage.create_session(
        SessionCreate(
            deviceId=payload.deviceId,
            sourceMode=payload.sourceMode,
            channelKeys=payload.channelKeys,
            startedAt=payload.startedAt,
        )
    )
    storage.upsert_device(
        DeviceUpsert(
            deviceId=payload.deviceId,
            sourceMode=payload.sourceMode,
            lastStatus='session_opened',
            metadata=payload.metadata,
        )
    )
    return record


@app.post('/api/v1/ingest/mqtt/catalog', response_model=ChannelCatalogRecord)
def ingest_catalog(payload: ChannelCatalogCreate) -> ChannelCatalogRecord:
    if storage.get_session(payload.sessionId) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.save_channel_catalog(payload)


@app.post('/api/v1/ingest/mqtt/frame-batch', response_model=RawChunkRecord)
def ingest_frame_batch(payload: FrameBatchIngest) -> RawChunkRecord:
    if storage.get_session(payload.sessionId) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.ingest_frame_batch(payload)


@app.post('/api/v1/ingest/mqtt/alerts', response_model=AlertRecord)
def ingest_alert(payload: AlertCreate) -> AlertRecord:
    if storage.get_session(payload.sessionId) is None:
        raise HTTPException(status_code=404, detail='Session not found')
    return storage.create_alert(payload)


@app.post('/api/v1/ingest/mqtt/device', response_model=DeviceRecord)
def upsert_device(payload: DeviceUpsert) -> DeviceRecord:
    return storage.upsert_device(payload)


@app.get('/api/v1/admin/overview', response_model=AdminOverview)
def admin_overview(x_admin_token: str | None = Header(default=None)) -> AdminOverview:
    _require_admin_token(x_admin_token)
    return storage.get_admin_overview()


@app.get('/api/v1/admin/sessions', response_model=list[AdminSessionItem])
def admin_sessions(x_admin_token: str | None = Header(default=None)) -> list[AdminSessionItem]:
    _require_admin_token(x_admin_token)
    return storage.list_admin_sessions(limit=100)


@app.get('/api/v1/admin/users', response_model=list[UserRecord])
def admin_users(x_admin_token: str | None = Header(default=None)) -> list[UserRecord]:
    _require_admin_token(x_admin_token)
    return storage.list_users()


@app.get('/api/v1/admin/sessions/{session_id}', response_model=SessionDetail)
def admin_session_detail(session_id: str, x_admin_token: str | None = Header(default=None)) -> SessionDetail:
    _require_admin_token(x_admin_token)
    try:
        return storage.get_session_detail(session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail='Session not found') from exc


@app.get('/api/v1/admin/devices', response_model=list[DeviceRecord])
def admin_devices(x_admin_token: str | None = Header(default=None)) -> list[DeviceRecord]:
    _require_admin_token(x_admin_token)
    return storage.list_devices()


@app.get('/api/v1/admin/alerts', response_model=list[AlertRecord])
def admin_alerts(x_admin_token: str | None = Header(default=None)) -> list[AlertRecord]:
    _require_admin_token(x_admin_token)
    return storage.list_alerts(limit=100)


def _require_admin_token(token: str | None) -> None:
    if settings.admin_token and token != settings.admin_token:
        raise HTTPException(status_code=401, detail='Invalid admin token')


def _segment_to_csv(segment: SegmentDetail) -> str:
    timestamps = sorted(
        {
            _sample_timestamp(channel.startTimestampMs, channel.sampleRate, index)
            for channel in segment.channels
            for index, _ in enumerate(channel.samples)
        }
    )
    channel_maps: dict[str, dict[int, float]] = {}
    for channel in segment.channels:
        channel_maps[channel.channelKey] = {
            _sample_timestamp(channel.startTimestampMs, channel.sampleRate, index): sample
            for index, sample in enumerate(channel.samples)
        }

    channel_keys = [channel.channelKey for channel in segment.channels]
    buffer = StringIO()
    writer = csv.writer(buffer)
    writer.writerow(['timestamp_ms', *channel_keys])
    for timestamp in timestamps:
        writer.writerow(
            [
                timestamp,
                *[channel_maps[channel_key].get(timestamp, 0) for channel_key in channel_keys],
            ]
        )
    return buffer.getvalue()


def _sample_timestamp(start_timestamp_ms: int, sample_rate: float, index: int) -> int:
    if sample_rate <= 0:
        return start_timestamp_ms + index
    return start_timestamp_ms + round(index * 1000 / sample_rate)
