# 云端联调速查卡

这份文档只保留现在最常用的入口、地址和命令，方便快速登录服务器、打开管理页面、检查 Broker 和云端状态。

## 1. 服务器信息

- 公网 IP：`182.254.220.56`
- 登录用户：`root`
- 登录方式：SSH

本地终端登录命令：

```powershell
ssh root@182.254.220.56
```

说明：
- 这条命令用于从你本机登录腾讯云服务器。
- 密码请使用你当前服务器实际在用的那一份，不要写进仓库文档。

## 2. 浏览器入口

- 云端 Swagger：`http://182.254.220.56:8000/docs`
- 云端健康检查：`http://182.254.220.56:8000/api/v1/health`
- 管理后台：`http://182.254.220.56:8080`
- EMQX Dashboard：`http://182.254.220.56:18083`

## 上位机入口
cd flutter_app
G:\课设\FlutterSDK\flutter\bin\flutter.bat pub get
G:\课设\FlutterSDK\flutter\bin\flutter.bat run -d chrome

说明：
- `8000` 是 `cloud_api`
- `8080` 是 `admin_web`
- `18083` 是 Broker 的 EMQX 控制台

## 3. 服务器上最常用的目录

- 项目根目录：`/root/cardio-monitor`
- 部署目录：`/root/cardio-monitor/deploy`
- 云端目录：`/root/cardio-monitor/cloud_server`

切换到部署目录：

```bash
cd /root/cardio-monitor/deploy
```

## 4. 查看容器状态

查看当前所有关键容器：

```bash
sudo docker ps
```

你现在主要应该看到这些：
- `emqx`
- `cardio-cloud-api`
- `cardio-cloud-worker`
- `cardio-admin-web`

如果想看 Compose 栈状态：

```bash
cd /root/cardio-monitor/deploy
sudo docker compose ps
```

## 5. 查看日志

### 5.1 Broker 日志

```bash
sudo docker logs --tail 100 emqx
```

持续追踪：

```bash
sudo docker logs -f emqx
```

### 5.2 云端 API 日志

```bash
cd /root/cardio-monitor/deploy
sudo docker compose logs --tail 100 cloud_api
```

持续追踪：

```bash
sudo docker compose logs -f cloud_api
```

### 5.3 管理后台日志

```bash
cd /root/cardio-monitor/deploy
sudo docker compose logs --tail 100 admin_web
```

### 5.4 Worker 日志

```bash
cd /root/cardio-monitor/deploy
sudo docker compose logs --tail 100 cloud_worker
```

## 6. 重启服务

重启整个云端栈：

```bash
cd /root/cardio-monitor/deploy
sudo docker compose up -d --build
```

只重启管理后台：

```bash
cd /root/cardio-monitor/deploy
sudo docker compose up -d --build admin_web
```

只重启 API：

```bash
cd /root/cardio-monitor/deploy
sudo docker compose up -d --build cloud_api
```

重启 Broker：

```bash
sudo docker restart emqx
```

## 7. Broker 当前联调参数

### 7.1 EMQX 端口

- MQTT TCP：`1883`
- MQTT over WebSocket：`8083`
- Dashboard：`18083`

### 7.2 当前最短链路

```text
ESP32(JSON over MQTT/TCP) -> EMQX Broker
                           -> 上位机(Flutter Web, MQTT over WebSocket)
                           -> 云端 mqtt_ingest
```

### 7.3 Topic 前缀

```text
cardio/{deviceId}/status
cardio/{deviceId}/catalog
cardio/{deviceId}/waveform/{channelKey}
cardio/{deviceId}/alerts
```

说明：
- 现在先按这套 JSON Topic 联调最快。
- 不要先切 MQTT binary，先把三端打通。

## 8. 上位机连接 Broker 时怎么填

在上位机选择 `WiFi / MQTT` 模式后，先这样填：

- Broker Host：`182.254.220.56`
- Port：`8083`
- WebSocket Path：`/mqtt`
- Device ID：和 ESP32 发布时用的 `deviceId` 完全一致
- Username / Password：如果 Broker 没开鉴权，先留空

## 9. 云端 ingest 配置

服务器上 `deploy/.env` 里和 MQTT 相关的关键项应为：

```env
CARDIO_MQTT_HOST=127.0.0.1
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

说明：
- 因为 Broker 和云端都在同一台服务器上，所以这里先用 `127.0.0.1`

## 10. MQTT 联调时最常用的排查顺序

### 第一步：确认 Broker 活着

```bash
sudo docker ps
sudo docker logs --tail 100 emqx
```

### 第二步：确认网页入口能打开

- `http://182.254.220.56:18083`
- `http://182.254.220.56:8000/docs`
- `http://182.254.220.56:8080`

### 第三步：确认上位机能连 Broker

现象：
- 上位机 MQTT 连接成功
- 没成功时先检查 `Host / Port / Path / Device ID`

### 第四步：确认 ESP32 真正在发 Topic

重点看：
- 是否真的发到了 `cardio/...`
- `deviceId` 是否和上位机填写一致
- payload 是否为 JSON

### 第五步：确认云端 ingest 在消费

看：
- `cloud_api` / `cloud_worker` 日志
- 管理后台
- `/api/v1/admin/devices`
- `/api/v1/admin/sessions`

## 11. 当前最值得记住的 5 条命令

登录服务器：

```powershell
ssh root@182.254.220.56
```

看容器：

```bash
sudo docker ps
```

看 Broker 日志：

```bash
sudo docker logs -f emqx
```

重启云端：

```bash
cd /root/cardio-monitor/deploy
sudo docker compose up -d --build
```

打开 Swagger：

```text
http://182.254.220.56:8000/docs
```
