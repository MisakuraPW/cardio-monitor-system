# EMQX Broker 部署方案与最短链路联调指南

## 1. 结论先说

如果你的目标是先把这条最短链路跑通：

```text
ESP32 -> Broker -> 上位机
                -> 云端 ingest
```

那么当前最推荐的 Broker 方案是：

- `EMQX`
- 部署在你现有的腾讯云服务器上
- 作为“云端里的独立服务”运行

这样做的好处是：

- Broker 也在云端，不需要再找第二台机器
- 上位机 Flutter Web 需要 `MQTT over WebSocket`，EMQX 原生支持更省事
- 云端 ingest 只要用普通 MQTT TCP 连接 Broker 即可
- 你还能用 Dashboard 直接看连接数、topic、消息流，联调非常方便

## 2. 我对你这个架构想法的判断

你的想法完全合理，而且是很推荐的：

```text
同一台云服务器上部署：
1. MQTT Broker
2. 业务后端 / 分析中心
3. 用户数据管理后台
```

只要注意一件事：

- 这三者可以部署在同一台服务器上
- 但它们不是同一个进程

也就是说：

- `EMQX` 负责协议层的消息中转
- `FastAPI cloud_server` 负责业务逻辑、数据落库、分析和未来大模型接入
- `admin_web` 负责可视化管理

这种拆法是对的，不冲突。

## 3. 为什么这一步推荐 EMQX，不推荐先上 Mosquitto

不是说 Mosquitto 不行，而是你当前这个项目更适合先用 EMQX。

### 3.1 选择 EMQX 的原因

- Flutter Web 上位机当前走的是 `MQTT over WebSocket`
- EMQX 自带 Dashboard，联调时非常好用
- EMQX 对 WebSocket、普通 MQTT、认证、监听器配置都更友好
- 后续如果你要做更复杂的云端消息治理，也更容易扩展

### 3.2 Mosquitto 的情况

Mosquitto 更轻，但你还要额外手写：

- WebSocket listener 配置
- 持久化配置
- 用户认证配置

对于“先跑通最短链路”来说，不如 EMQX 省心。

## 4. 当前最短链路的准确理解

现在先不要把目标理解成：

```text
ESP32 -> 云端后端 -> 上位机
```

因为当前代码还没有做“云端实时转发给上位机”。

当前最短链路应该理解成：

```text
ESP32 -> EMQX Broker -> 上位机 MQTT 直连显示
                   -> 云端 mqtt_ingest 订阅并落库
```

这条链路跑通以后，你就已经具备：

- 实时显示
- 云端存档
- 后台查看

再往后才是：

- 云端统一实时转发
- 云端分析回传
- 大模型接入

## 5. 官方依据

我这份方案参考了 EMQX 官方文档里当前可查到的信息：

- EMQX 支持通过 Docker 快速部署  
  来源：EMQX 官方文档  
  https://docs.emqx.com/en/emqx/latest/getting-started/getting-started.html

- EMQX Dashboard 默认端口是 `18083`，首次登录默认用户名密码是 `admin / public`  
  来源：EMQX Dashboard 文档  
  https://docs.emqx.com/en/emqx/latest/dashboard/introduction.html

- EMQX 默认监听的关键端口包括：
  - `1883` MQTT/TCP
  - `8083` MQTT over WebSocket
  - `18083` Dashboard  
  来源：EMQX 安装与部署 FAQ / 安装文档  
  https://docs.emqx.com/en/emqx/latest/faq/deployment.html  
  https://docs.emqx.com/en/emqx/latest/deploy/install.html

## 6. 推荐部署方案

## 6.1 服务器角色划分

你这台腾讯云服务器建议同时运行以下服务：

- `EMQX Broker`
- `cloud_api`
- `cloud_worker`
- `cloud_mqtt_ingest`
- `admin_web`

逻辑结构如下：

```text
ESP32
  -> EMQX (1883 MQTT TCP)

Flutter Web 上位机
  -> EMQX (8083 MQTT over WebSocket)

cloud_server mqtt_ingest
  -> EMQX (1883 MQTT TCP 订阅)

admin_web
  -> cloud_api
```

## 6.2 推荐开放的端口

调试阶段建议放开：

- `1883/TCP`
  - ESP32 -> EMQX
- `8083/TCP`
  - Flutter Web -> EMQX WebSocket
- `18083/TCP`
  - 你登录 EMQX Dashboard
- `8000/TCP`
  - cloud_api
- `8080/TCP`
  - admin_web

如果暂时不做 TLS，可以先不开放：

- `8883`
- `8084`

## 7. 推荐部署方式

当前最推荐：

- 直接用 Docker 单容器方式先把 EMQX 起起来
- 跑通后再考虑把它合并进 `docker-compose`

原因：

- 你现在目标是“先联调成功”
- 先减少编排复杂度
- 单容器起步最容易定位问题

## 8. 在云服务器上的完整部署步骤

以下假设你已经：

- 安装好了 Docker
- 已经能在服务器上运行 `docker`

## 8.1 创建 Broker 数据目录

```bash
mkdir -p /root/emqx/data
mkdir -p /root/emqx/log
```

作用：

- 持久化 EMQX 的数据和日志
- 避免容器重建后状态全丢

## 8.2 拉取 EMQX 镜像

```bash
sudo docker pull emqx/emqx-enterprise:6.2.0
```

作用：

- 拉取官方文档当前可见的 Docker 镜像版本示例

说明：

- 我这里采用的是官方文档当前示例里的 `6.2.0`
- 如果你后续要固定版本，就继续沿用这个
- 如果你后续自己换版本，记得文档和命令一起改

## 8.3 启动 EMQX 容器

```bash
sudo docker run -d \
  --name emqx \
  --restart unless-stopped \
  --hostname broker.cardio.local \
  -e "EMQX_NODE_NAME=emqx@broker.cardio.local" \
  -p 1883:1883 \
  -p 8083:8083 \
  -p 18083:18083 \
  -v /root/emqx/data:/opt/emqx/data \
  -v /root/emqx/log:/opt/emqx/log \
  emqx/emqx-enterprise:6.2.0
```

这条命令的作用：

- 启动一个单节点 EMQX
- 开放最短链路需要的 3 个端口
- 固定节点名，避免持久化路径混乱
- 把数据和日志挂到宿主机

## 8.4 查看容器状态

```bash
sudo docker ps
```

正常你应该能看到：

- 一个名为 `emqx` 的容器处于 `Up`

## 8.5 查看 Broker 日志

```bash
sudo docker logs -f emqx
```

作用：

- 看 EMQX 有没有启动报错
- 看监听器是否正常加载

如果看到类似“started”或监听端口就绪的信息，一般说明启动成功。

## 8.6 打开 Dashboard

浏览器访问：

```text
http://182.254.220.56:18083
```

首次登录默认：

- 用户名：`admin`
- 密码：`public`

首次登录后，EMQX 会强制你修改默认密码。

## 8.7 云平台安全组 / 防火墙放行

你要在腾讯云控制台放行：

- `1883`
- `8083`
- `18083`

如果只想本地自己调试 Dashboard，也可以先只开放：

- `1883`
- `8083`

然后暂时不对公网开放 `18083`，改成只服务器本机访问。

## 9. 联调时三端怎么配

## 9.1 ESP32 怎么配

ESP32 先按当前代码最短路径走：

- MQTT Host：你的云服务器 IP
- MQTT Port：`1883`
- Topic Prefix：`cardio`
- 先发 JSON，不要先发二进制 MQTT

建议设备主题统一为：

```text
cardio/{deviceId}/status
cardio/{deviceId}/catalog
cardio/{deviceId}/waveform/{channelKey}
cardio/{deviceId}/alerts
```

## 9.2 上位机怎么配

上位机切到 `WiFi / MQTT` 模式，填：

- Broker Host：你的云服务器 IP(182.254.220.56)
- Port：`8083`
- WebSocket Path：`/mqtt`
- Device ID：和 ESP32 主题里的 `{deviceId}` 保持一致

注意：

- 上位机 Flutter Web 走的是 WebSocket，不是普通 TCP
- 所以端口要填 `8083`

## 9.3 云端 ingest 怎么配

在云端 `.env` 或运行环境里设置：

```env
CARDIO_MQTT_HOST=127.0.0.1
CARDIO_MQTT_PORT=1883
CARDIO_MQTT_TOPIC_PREFIX=cardio
```

作用：

- 因为 Broker 和云端在同一台服务器上
- 所以云端 ingest 可以直接连 `127.0.0.1:1883`

然后启动：

```bash
cd /root/cardio-monitor/cloud_server
source .venv/bin/activate
PYTHONPATH=$(pwd) python -m app.mqtt_ingest_runner
```

如果你仍然在 Windows 环境本地联调，则用你现有的 Windows 启动命令即可。

## 10. 推荐的调试顺序

严格按这个顺序来。

### 第一步：只验证 Broker 本身

你先只看：

- `http://服务器IP:18083`
- Dashboard 能否打开

然后再看：

- 容器日志是否正常

### 第二步：只验证上位机能否连 Broker

这一步先不管云端 ingest。

你只要让上位机能连上 Broker，并在 Dashboard 里看到连接数变化即可。

### 第三步：只验证 ESP32 能否发到 Broker

这一步建议用：

- `MQTTX`
- 或 EMQX Dashboard 自带的 topic 观察能力

你需要确认：

- `cardio/{deviceId}/status`
- `cardio/{deviceId}/catalog`
- `cardio/{deviceId}/waveform/{channelKey}`

真的有消息进 Broker。

### 第四步：只验证云端 ingest 是否吃到消息

Broker 已有消息后，再去看：

- `mqtt_ingest_runner` 日志
- `admin_web`
- `/api/v1/admin/devices`
- `/api/v1/admin/sessions`

## 11. 当前阶段不建议一上来做的事

这几件事先不要同时做，否则排查会很乱：

- 一开始就接 MQTT 二进制 `BIO1`
- 一开始就要求“云端转发给上位机”
- 一开始就接大模型
- 一开始就把 TLS / WSS 全开

先跑最短链路：

```text
ESP32(JSON) -> EMQX -> 上位机
                    -> 云端 ingest
```

这是当前成功率最高的路径。

## 12. 这一步之后还要补什么

Broker 部署完成后，后续真正要补的能力有：

### 12.1 云端实时转发给上位机

当前还没有：

- 云端 WebSocket 推流
- 云端 MQTT 网关转发

### 12.2 MQTT 二进制支持

当前 BLE 已经走 `BIO1`，但 MQTT 还没有打通二进制解析。

### 12.3 metrics 入链路

当前上位机订阅了 `metrics`，但并没有完整展示链路。

### 12.4 自动 session 管理

现在还需要先创建 session，再让设备带着 `sessionId` 发。

## 13. 最终建议

你的总体想法没有问题：

- Broker 部署在云端
- 云端同时负责数据管理、分析中心、未来大模型接口

这是很合理的系统形态。

但是第一步一定要拆小。

当前最稳的顺序就是：

1. 先把 `EMQX Broker` 起起来
2. 再打通 `ESP32 -> Broker -> 上位机`
3. 再打通 `Broker -> 云端 ingest`
4. 最后再做“云端统一中转”和“大模型分析”

如果你愿意，下一步我可以继续直接给你：

- 一份“EMQX 启动后在 Dashboard 里需要点哪里”的操作清单
- 或者一份“把 EMQX 合并进你现有 `docker-compose` 的版本”
