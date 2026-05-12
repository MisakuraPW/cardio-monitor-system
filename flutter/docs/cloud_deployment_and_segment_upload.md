# 云端部署与自动分段上传指南

本文面向演示部署：Flutter 上位机在本地电脑运行，服务器只部署 FastAPI 云端服务、分析 Worker、MQTT ingest 和 Admin Web。

## 1. 部署方式选择

推荐使用 Git 拉取部署。

原因：

- 后续更新只需要在服务器执行 `git pull`。
- Docker Compose 已经在 `flutter/deploy/docker-compose.yml` 中配置好。
- 比本地压缩包上传更不容易漏文件。

本地压缩上传只适合临时没有远程仓库的情况，不作为主流程。

## 2. 本地提交并推送

在本地仓库根目录执行：

```powershell
cd G:\课设\system\cardio-monitor-system
git status
git add .
git commit -m "Add cloud segment upload and admin playback"
git push
```

如果 VS Code 提示 `index.lock`，先确认没有其他 Git 操作正在运行，再删除 `.git/index.lock` 后重试。

## 3. 服务器首次部署

登录服务器：

```bash
ssh root@182.254.220.56
```

安装基础工具：

```bash
sudo dnf makecache
sudo dnf install -y git docker docker-compose-plugin
sudo systemctl enable --now docker
```

拉取项目：

```bash
mkdir -p /root/cardio-monitor
cd /root/cardio-monitor
git clone <你的远程仓库地址> cardio-monitor-system
cd cardio-monitor-system/flutter/deploy
cp .env.example .env
```

编辑 `.env`：

```bash
vi .env
```

演示推荐配置：

```env
CARDIO_APP_ENV=production
CARDIO_ANALYSIS_EXECUTION_MODE=queue
CARDIO_ANALYSIS_PROVIDER=closed_source
CARDIO_ADMIN_TOKEN=change-me
CARDIO_ADMIN_WEB_API_BASE_URL=http://182.254.220.56:8000
CARDIO_MQTT_HOST=host.docker.internal
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

请把 `CARDIO_ADMIN_TOKEN` 改成自己的后台密码。

启动：

```bash
sudo docker compose up -d --build
sudo docker compose ps
```

检查地址：

```text
FastAPI: http://182.254.220.56:8000/docs
Admin Web: http://182.254.220.56:8080
```

## 4. 后续更新

服务器上执行：

```bash
cd /root/cardio-monitor/cardio-monitor-system
git pull
cd flutter/deploy
sudo docker compose up -d --build
```

查看日志：

```bash
sudo docker compose logs -f cloud_api
sudo docker compose logs -f cloud_worker
sudo docker compose logs -f admin_web
```

## 5. 本地上位机配置

启动 Flutter 上位机后：

1. 云端地址填写 `http://182.254.220.56:8000`。
2. 用户姓名 / 编号填写本次演示对象，例如 `演示用户`。
3. WiFi / MQTT 配置继续使用现有 Broker。
4. 点击连接 / 开始。

连接后，上位机会自动创建云端会话，并每约 20 秒上传一个分段。

## 6. 自动分段上传逻辑

当前默认：

- 分段长度：20 秒。
- ECG 500Hz 时，每段约 10000 点。
- PPG 按自身采样率自然少一些。
- IMU 六轴不进入演示实时波形。
- 上传内容包含原始/滤波 ECG、PPG、通道摘要、本地 DSP 指标、质量分和通信统计。

上传成功后，上位机本地只保留最近约 30 秒波形数据，用于降低长时间演示时的内存和绘图压力。

如果上传失败：

- 上位机会在内存中最多保留 3 个待上传分段。
- 超过 3 段后丢弃最旧待上传段。
- 这样可以保证演示流畅度优先，不会因为网络问题把浏览器拖卡。

## 7. 管理后台回溯

打开：

```text
http://182.254.220.56:8080
```

推荐演示路径：

1. 进入“用户”。
2. 点击用户姓名 / 编号。
3. 选择该用户的一次会话。
4. 在“分段回溯”里点击 `#0`、`#1`、`#2` 等分段。
5. 查看 ECG、ECG filtered、PPG IR、PPG IR filtered、PPG RED、PPG RED filtered 的波形预览。

后台默认不显示 IMU 六轴，保持页面轻量。

## 8. 大模型接口预留

云端已经保留 OpenAI-compatible `/chat/completions` 调用方式。

闭源模型配置：

```env
CARDIO_ANALYSIS_PROVIDER=closed_source
CARDIO_LLM_API_BASE_URL=https://api.example.com/v1
CARDIO_LLM_API_KEY=你的key
CARDIO_LLM_MODEL=模型名
CARDIO_LLM_PROMPT_VERSION=v1
```

本地开源模型配置：

```env
CARDIO_ANALYSIS_PROVIDER=open_source
CARDIO_LOCAL_LLM_BASE_URL=http://127.0.0.1:11434/v1
CARDIO_LOCAL_LLM_MODEL=模型名
```

演示建议：

- 不把完整高频波形直接塞进 prompt。
- 先由规则和 DSP 指标生成结构化摘要。
- 大模型只做解释、总结、建议文案和报告润色。

## 9. 常见问题

### 上位机无法上传

先打开：

```text
http://182.254.220.56:8000/docs
```

如果打不开，说明云端服务没有正常运行或服务器防火墙未放行 `8000`。

### 管理后台没有数据

确认：

- 上位机云端地址是服务器地址。
- 上位机已经连接并运行超过 20 秒。
- `cloud_api` 容器正在运行。
- `CARDIO_ADMIN_TOKEN` 与 Admin Web 构建时的配置一致。

### 服务器更新后页面没变化

重新构建容器：

```bash
cd /root/cardio-monitor/cardio-monitor-system/flutter/deploy
sudo docker compose up -d --build admin_web cloud_api
```

然后浏览器强制刷新。

