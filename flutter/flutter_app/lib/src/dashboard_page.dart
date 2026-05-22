import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'monitor_controller.dart';

const double _waveformYAxisWidth = 56;

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final MonitorController _controller;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _pathController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _cloudController;
  late final TextEditingController _userNameController;
  late final TextEditingController _bleNamePrefixController;
  late final TextEditingController _bleServiceController;
  late final TextEditingController _bleNotifyController;
  late final TextEditingController _bleControlController;
  late final Listenable _waveformListenable;

  int _sidePanelIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller = MonitorController();
    _waveformListenable = Listenable.merge(<Listenable>[
      _controller,
      _controller.waveformNotifier,
    ]);
    _hostController = TextEditingController(text: _controller.mqttConfig.host);
    _portController = TextEditingController(text: _controller.mqttConfig.port.toString());
    _pathController = TextEditingController(text: _controller.mqttConfig.path);
    _deviceIdController = TextEditingController(text: _controller.mqttConfig.deviceId);
    _usernameController = TextEditingController(text: _controller.mqttConfig.username);
    _passwordController = TextEditingController(text: _controller.mqttConfig.password);
    _cloudController = TextEditingController(text: _controller.cloudBaseUrl);
    _userNameController = TextEditingController(text: _controller.userName);
    _bleNamePrefixController = TextEditingController(text: _controller.bluetoothConfig.deviceNamePrefix);
    _bleServiceController = TextEditingController(text: _controller.bluetoothConfig.serviceUuid);
    _bleNotifyController = TextEditingController(text: _controller.bluetoothConfig.notifyCharacteristicUuid);
    _bleControlController = TextEditingController(text: _controller.bluetoothConfig.controlCharacteristicUuid);
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _pathController.dispose();
    _deviceIdController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _cloudController.dispose();
    _userNameController.dispose();
    _bleNamePrefixController.dispose();
    _bleServiceController.dispose();
    _bleNotifyController.dispose();
    _bleControlController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('多源心肺功能监测上位机'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (BuildContext context, Widget? child) =>
                    _StatusBadge(status: _controller.status),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final isCompact = constraints.maxWidth < 1180;
          final content = <Widget>[
            SizedBox(
              width: isCompact ? double.infinity : 400,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (BuildContext context, Widget? child) =>
                    _buildControlPanel(context),
              ),
            ),
            SizedBox(width: isCompact ? 0 : 20, height: isCompact ? 20 : 0),
            Expanded(
              child: AnimatedBuilder(
                animation: _waveformListenable,
                builder: (BuildContext context, Widget? child) =>
                    _buildWaveformArea(context),
              ),
            ),
          ];

          return Padding(
            padding: const EdgeInsets.all(20),
            child: isCompact
                ? Column(children: content)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: content,
                  ),
          );
        },
      ),
    );
  }

  Widget _buildControlPanel(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('功能分区', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('配置与记录'),
                          selected: _sidePanelIndex == 0,
                          onSelected: (_) => setState(() => _sidePanelIndex = 0),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('控制与分析'),
                          selected: _sidePanelIndex == 1,
                          onSelected: (_) => setState(() => _sidePanelIndex = 1),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _sidePanelIndex == 0
                        ? '用于切换数据源、配置连接参数和查看运行日志。'
                        : '用于控制波形显示，并查看本地统计与云端分析结果。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_sidePanelIndex == 0) ...<Widget>[
            _buildDataSourceCard(context),
            const SizedBox(height: 16),
            _buildTransportDiagnosticsCard(context),
            const SizedBox(height: 16),
            _buildStatusLogCard(context),
          ] else ...<Widget>[
            _buildDisplayControlCard(context),
            const SizedBox(height: 16),
            _buildChannelCatalogCard(context),
            const SizedBox(height: 16),
            _buildLocalAnalysisCard(context),
            const SizedBox(height: 16),
            _buildCloudAnalysisCard(context),
          ],
        ],
      ),
    );
  }

  Widget _buildDataSourceCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('数据源', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: DataSourceMode.values.map((DataSourceMode item) {
                return ChoiceChip(
                  label: Text(item.label),
                  selected: _controller.mode == item,
                  onSelected: (_) => _controller.setMode(item),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            _buildTextField('用户姓名 / 编号', _userNameController, (String value) {
              _controller.updateUserName(value);
            }),
            const SizedBox(height: 12),
            if (_controller.mode == DataSourceMode.wifi) ...<Widget>[
              _buildTextField('Broker Host', _hostController, (String value) {
                _controller.updateMqttConfig(host: value);
              }),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _buildTextField('端口', _portController, (String value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null) {
                        _controller.updateMqttConfig(port: parsed);
                      }
                    }),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField('WebSocket Path', _pathController, (String value) {
                      _controller.updateMqttConfig(path: value);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildTextField('设备 ID', _deviceIdController, (String value) {
                _controller.updateMqttConfig(deviceId: value);
              }),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _buildTextField('用户名', _usernameController, (String value) {
                      _controller.updateMqttConfig(username: value);
                    }),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField('密码', _passwordController, (String value) {
                      _controller.updateMqttConfig(password: value);
                    }, obscureText: true),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 TLS / WSS'),
                value: _controller.mqttConfig.useTls,
                onChanged: (bool value) => _controller.updateMqttConfig(useTls: value),
              ),
            ],
            if (_controller.mode == DataSourceMode.file) ...<Widget>[
              FilledButton.tonalIcon(
                onPressed: _controller.pickReplayFile,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('选择 CSV / JSON'),
              ),
              const SizedBox(height: 10),
              Text(_controller.hasReplayFile ? '当前文件: ${_controller.replayFileName}' : '未选择回放文件'),
              const SizedBox(height: 8),
              const Text('建议先用仓库里的长样例 CSV 验证滚动、暂停和回滚功能。'),
            ],
            if (_controller.mode == DataSourceMode.bluetooth) ...<Widget>[
              _buildTextField('设备名前缀', _bleNamePrefixController, (String value) {
                _controller.updateBluetoothConfig(deviceNamePrefix: value);
              }),
              const SizedBox(height: 12),
              _buildTextField('服务 UUID', _bleServiceController, (String value) {
                _controller.updateBluetoothConfig(serviceUuid: value);
              }),
              const SizedBox(height: 12),
              _buildTextField('通知特征 UUID', _bleNotifyController, (String value) {
                _controller.updateBluetoothConfig(notifyCharacteristicUuid: value);
              }),
              const SizedBox(height: 12),
              _buildTextField('控制特征 UUID', _bleControlController, (String value) {
                _controller.updateBluetoothConfig(controlCharacteristicUuid: value);
              }),
              const SizedBox(height: 8),
              const Text('蓝牙模式基于 Web Bluetooth，默认按 esp32-bio 设备名前缀筛选，并按 BIO1 二进制帧解析 Notify 数据。页面仍需运行在 Chrome / Edge 的 HTTPS 或 localhost 环境下。'),
            ],
            const SizedBox(height: 16),
            Text(
              '自动分段: 每 20 秒上传一次，已上传 ${_controller.uploadedSegmentCount} 段，待上传 ${_controller.pendingSegmentUploadCount} 段，失败 ${_controller.failedSegmentUploadCount} 段。',
            ),
            if (_controller.latestSegment != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('最近分段: #${_controller.latestSegment!.segmentIndex} / ${_controller.latestSegment!.sampleCount} 点'),
              ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _controller.isConnected
                        ? _controller.disconnect
                        : () {
                            _syncConnectionFieldsToController();
                            _controller.connect();
                          },
                    icon: Icon(_controller.isConnected ? Icons.stop_circle_outlined : Icons.play_arrow),
                    label: Text(_controller.isConnected ? '断开 / 停止' : '连接 / 开始'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildDisplayControlCard(BuildContext context) {
    final maxOffset = _controller.maxHistoryOffsetSeconds;
    final historySliderMax = maxOffset <= 0 ? 1.0 : maxOffset;
    final historySliderValue = _controller.isPaused
        ? _controller.historyOffsetSeconds.clamp(0.0, historySliderMax)
        : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('显示控制', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _controller.togglePause,
                    icon: Icon(_controller.isPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(_controller.isPaused ? '继续播放' : '暂停回看'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _controller.isPaused
                  ? '当前已暂停，历史回滚已解锁；点击继续播放会自动回到最新位置。'
                  : '当前处于实时播放状态，历史回滚锁定并自动跟随最新数据。',
            ),
            const SizedBox(height: 16),
            Text('时间窗: ${_controller.secondsPerScreen.toStringAsFixed(1)} s'),
            Slider(
              value: _controller.secondsPerScreen,
              min: 2,
              max: 20,
              divisions: 18,
              onChanged: _controller.setSecondsPerScreen,
            ),
            Text(
              '实时延迟缓冲: ${_controller.liveDisplayLagSeconds.toStringAsFixed(1)} s',
            ),
            Slider(
              value: _controller.liveDisplayLagSeconds,
              min: 0,
              max: 6,
              divisions: 24,
              onChanged: _controller.setLiveDisplayLagSeconds,
            ),
            const Text(
              '实时播放采用软同步：右侧边界跟随全局最新数据，各通道仍按真实时间戳对齐；某一路短暂停顿时会留空并标记滞后，不再拖住整屏。',
            ),
            const SizedBox(height: 8),
            Text(_controller.isPaused ? '历史回滚: ${historySliderValue.toStringAsFixed(1)} s' : '历史回滚: 实时锁定'),
            Slider(
              value: historySliderValue,
              min: 0,
              max: historySliderMax,
              onChanged: _controller.canRollbackHistory ? _controller.setHistoryOffsetSeconds : null,
            ),
            if (_controller.isPaused && !_controller.canRollbackHistory)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('当前缓存长度不足一个完整时间窗，已补长样例 CSV 供调试使用。'),
              ),
            Text('增益: ${_controller.gain.toStringAsFixed(1)} x'),
            Slider(
              value: _controller.gain,
              min: 0.5,
              max: 4,
              divisions: 14,
              onChanged: _controller.setGain,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelCatalogCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('通道显隐', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_controller.channelCatalog.isEmpty)
              const Text('当前尚未收到通道目录，可以先导入文件或连接 ESP32。'),
            for (final ChannelDescriptor channel in _controller.channelCatalog)
              SwitchListTile.adaptive(
                value: channel.enabled,
                contentPadding: EdgeInsets.zero,
                title: Text('${channel.label} (${channel.unit})'),
                subtitle: Text('${channel.sampleRate.toStringAsFixed(1)} Hz'),
                secondary: CircleAvatar(
                  radius: 8,
                  backgroundColor: colorFromHex(channel.colorHex),
                ),
                onChanged: (bool value) => _controller.toggleChannel(channel.key, value),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocalAnalysisCard(BuildContext context) {
    final analysis = _controller.localAnalysis;
    final physio = analysis.physio;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('本地统计与分析', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('基于缓冲信号的轻量统计与生理参数估算，供参考使用。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _MetricChip(label: '启用通道', value: '${analysis.activeChannels}'),
                _MetricChip(label: '最长时长', value: '${analysis.durationSeconds.toStringAsFixed(1)} s'),
                _MetricChip(label: '平均质量', value: '${(analysis.meanQuality * 100).toStringAsFixed(0)} %'),
              ],
            ),
            if (physio.hasAny) ...<Widget>[
              const SizedBox(height: 16),
              Text('生理参数估算', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (physio.heartRateBpm != null)
                    _MetricChip(label: '心率', value: '${physio.heartRateBpm!.toStringAsFixed(1)} BPM'),
                  if (physio.hrvRmssd != null)
                    _MetricChip(label: 'HRV RMSSD', value: '${physio.hrvRmssd!.toStringAsFixed(1)} ms'),
                  if (physio.hrvSdnn != null)
                    _MetricChip(label: 'HRV SDNN', value: '${physio.hrvSdnn!.toStringAsFixed(1)} ms'),
                  if (physio.hrvPnn50 != null)
                    _MetricChip(label: 'pNN50', value: '${physio.hrvPnn50!.toStringAsFixed(1)} %'),
                  if (physio.respiratoryRateBpm != null)
                    _MetricChip(label: '呼吸频率', value: '${physio.respiratoryRateBpm!.toStringAsFixed(1)} 次/min'),
                  if (physio.spo2Percent != null)
                    _MetricChip(label: 'SpO₂ 估算', value: '${physio.spo2Percent!.toStringAsFixed(1)} %'),
                  if (physio.temperatureCelsius != null)
                    _MetricChip(label: '体温', value: '${physio.temperatureCelsius!.toStringAsFixed(2)} °C'),
                ],
              ),
              if (physio.notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(physio.notes.join(' · '), style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
            const SizedBox(height: 16),
            Text('即时结论', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (analysis.findings.isEmpty) const Text('暂无本地分析结论'),
            ...analysis.findings.map(
              (String item) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _FindingTile(text: item),
              ),
            ),
            const SizedBox(height: 12),
            Text('通道统计', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (analysis.channels.isEmpty) const Text('暂无可统计的通道数据'),
            ...analysis.channels.map(
              (LocalChannelAnalysis item) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFDCE3EA)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text('${item.label} (${item.unit})', style: Theme.of(context).textTheme.titleSmall),
                          const Spacer(),
                          if (item.estimatedRateBpm != null)
                            Text('${item.estimatedRateBpm!.toStringAsFixed(1)} BPM'),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          _MetricChip(label: '样本', value: '${item.sampleCount}'),
                          _MetricChip(label: '均值', value: item.mean.toStringAsFixed(3)),
                          _MetricChip(label: '峰峰值', value: item.peakToPeak.toStringAsFixed(3)),
                          _MetricChip(label: 'RMS', value: item.rms.toStringAsFixed(3)),
                          _MetricChip(label: '标准差', value: item.stdDev.toStringAsFixed(3)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('范围 ${item.min.toStringAsFixed(3)} ~ ${item.max.toStringAsFixed(3)}，时长 ${item.durationSeconds.toStringAsFixed(1)} s，质量 ${(item.meanQuality * 100).toStringAsFixed(0)} %'),
                      if (item.notes.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(item.notes.join(' · ')),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudAnalysisCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('云端分析', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _buildTextField('云端地址', _cloudController, (String value) {
              _controller.updateCloudBaseUrl(value);
            }),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _controller.uploadAndAnalyze,
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('上传并分析'),
                  ),
                ),
              ],
            ),
            if (_controller.uploadTask != null) ...<Widget>[
              const SizedBox(height: 12),
              Text('上传任务: ${_controller.uploadTask!.id}'),
              Text('状态: ${_controller.uploadTask!.status}'),
            ],
            if (_controller.latestSegment != null) ...<Widget>[
              const SizedBox(height: 12),
              Text('最近自动分段: #${_controller.latestSegment!.segmentIndex} / ${_controller.latestSegment!.sampleCount} 点'),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _controller.analyzeLatestSegment,
                icon: const Icon(Icons.psychology_alt_outlined),
                label: const Text('分析最近分段'),
              ),
            ],
            if (_controller.analysisJob != null) ...<Widget>[
              const SizedBox(height: 12),
              Text('分析任务: ${_controller.analysisJob!.id}'),
              Text('状态: ${_controller.analysisJob!.status}'),
              if (_controller.analysisJob!.summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_controller.analysisJob!.summary),
                ),
            ],
            if (_controller.report != null) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFDCE3EA)),
                ),
                child: Text(_controller.report!.summary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusLogCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('状态日志', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_controller.events.isEmpty) const Text('尚无日志'),
            ..._controller.events.take(14).map(
              (String item) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(item),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTransportDiagnosticsCard(BuildContext context) {
    final stats = _controller.transportStats;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Transport diagnostics', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (stats.isEmpty)
              const Text('Waiting for firmware/server metrics.'),
            for (final TransportStats item in stats) ...<Widget>[
              Text('${item.source} ${item.deviceId.isEmpty ? '' : '· ${item.deviceId}'}'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _MetricChip(label: 'pub fail', value: '${item.publishFailCount}'),
                  _MetricChip(label: 'crc', value: '${item.crcErrorCount}'),
                  _MetricChip(label: 'decode', value: '${item.decodeErrorCount}'),
                  _MetricChip(label: 'wifi', value: '${item.wifiReconnectCount}'),
                  _MetricChip(label: 'latency', value: '${item.lastPublishLatencyMs} ms'),
                ],
              ),
              const SizedBox(height: 8),
              _buildStatsMap('queue', item.queueDepth),
              _buildStatsMap('drop', item.dropCount),
              _buildStatsMap('overwrite', item.overwriteCount),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatsMap(String label, Map<String, int> values) {
    if (values.isEmpty) {
      return Text('$label: -');
    }
    final text = values.entries
        .map((MapEntry<String, int> item) => '${item.key}=${item.value}')
        .join('  ');
    return Text('$label: $text');
  }

  Widget _buildWaveformArea(BuildContext context) {
    final visibleChannels = _controller.visibleChannels;
    return Column(
      children: <Widget>[
        Card(
          child: ListTile(
            title: Text(_controller.session == null ? '等待开始监测' : '会话 ${_controller.session!.id}'),
            subtitle: Text(
              _controller.session == null
                  ? '请先连接 MQTT / 蓝牙设备，或导入回放文件。'
                  : '设备 ${_controller.session!.deviceId} | 模式 ${_controller.session!.sourceMode} | 通道 ${_controller.session!.channelKeys.join(', ')}',
            ),
            trailing: _MetricChip(label: '锚点', value: _controller.isPaused ? '暂停回看' : '实时最新'),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: visibleChannels.isEmpty
              ? Card(
                  child: Center(
                    child: Text(
                      '暂无可显示的通道\n请先导入数据文件、连接 MQTT 或连接蓝牙设备',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: visibleChannels.length + (_controller.report != null ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(height: 16),
                  itemBuilder: (BuildContext context, int index) {
                    if (_controller.report != null && index == visibleChannels.length) {
                      return _ReportCard(report: _controller.report!);
                    }
                    final channel = visibleChannels[index];
                    final waveform = _controller.visibleWaveform(channel.key);
                    return _WaveformCard(
                      channel: channel,
                      points: waveform.points,
                      minValue: waveform.minValue,
                      maxValue: waveform.maxValue,
                      gain: _controller.gain,
                      secondsPerScreen: _controller.secondsPerScreen,
                      anchorTimestampMs: _controller.currentAnchorTimestampMs,
                      summary: _controller.channelSummary(channel.key),
                      runtime: _controller.channelRuntime(channel.key),
                      enableHoverInspect: _controller.isPaused,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTextField(String label, TextEditingController controller, ValueChanged<String> onChanged, {bool obscureText = false}) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  void _syncConnectionFieldsToController() {
    final parsedPort = int.tryParse(_portController.text.trim());
    _controller.updateMqttConfig(
      host: _hostController.text.trim(),
      port: parsedPort,
      path: _pathController.text.trim(),
      useTls: _controller.mqttConfig.useTls,
      deviceId: _deviceIdController.text.trim(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
    );
    _controller.updateCloudBaseUrl(_cloudController.text.trim());
    _controller.updateUserName(_userNameController.text.trim());
  }
}
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final AdapterStatus status;

  @override
  Widget build(BuildContext context) {
    Color background;
    switch (status.state) {
      case AdapterState.streaming:
        background = const Color(0xFFD7F9E9);
        break;
      case AdapterState.connected:
        background = const Color(0xFFE6F4FF);
        break;
      case AdapterState.error:
        background = const Color(0xFFFFE5E5);
        break;
      default:
        background = const Color(0xFFF1F3F5);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(status.message),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6FBF8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD5E7DD)),
      ),
      child: Text('$label  $value'),
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFDCE3EA)),
      ),
      child: Text(text),
    );
  }
}

class _WaveformCard extends StatefulWidget {
  const _WaveformCard({
    required this.channel,
    required this.points,
    required this.minValue,
    required this.maxValue,
    required this.gain,
    required this.secondsPerScreen,
    required this.anchorTimestampMs,
    required this.summary,
    required this.runtime,
    required this.enableHoverInspect,
  });

  final ChannelDescriptor channel;
  final List<SamplePoint> points;
  final double minValue;
  final double maxValue;
  final double gain;
  final double secondsPerScreen;
  final int anchorTimestampMs;
  final Map<String, dynamic> summary;
  final ChannelRuntimeStats runtime;
  final bool enableHoverInspect;

  @override
  State<_WaveformCard> createState() => _WaveformCardState();
}

class _WaveformCardState extends State<_WaveformCard> {
  HoverSampleInfo? _hoverInfo;
  _WaveformViewport? _stableViewport;
  int _lastHoverUpdateMs = 0;

  @override
  void didUpdateWidget(covariant _WaveformCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.points.isEmpty && _hoverInfo != null) {
      _hoverInfo = null;
    }
    if (!widget.enableHoverInspect && _hoverInfo != null) {
      _hoverInfo = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final estimatedRate = _safeNullableDouble(widget.summary['estimatedRateBpm']);
    final runtime = widget.runtime;
    final healthText = runtime.healthText(widget.anchorTimestampMs);
    final lagSeconds = runtime.lagBehindAnchorSeconds(widget.anchorTimestampMs);
    final idleSeconds = runtime.idleSeconds();
    final viewport = _resolveStableViewport(_targetViewport());

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 8,
                  backgroundColor: colorFromHex(widget.channel.colorHex),
                ),
                const SizedBox(width: 10),
                Text('${widget.channel.label} (${widget.channel.unit})', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${widget.channel.sampleRate.toStringAsFixed(1)} Hz · $healthText'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '样本 ${widget.summary['samples'] ?? 0} | 帧 ${runtime.receivedFrames} | 缺包 ${runtime.missingFrames} | 断档 ${runtime.sampleGapEvents} | 空闲 ${idleSeconds.toStringAsFixed(1)} s | 滞后 ${lagSeconds.toStringAsFixed(1)} s',
            ),
            const SizedBox(height: 4),
            Text(
              '均值 ${_safeDouble(widget.summary['mean']).toStringAsFixed(3)} | 范围 ${_safeDouble(widget.summary['min']).toStringAsFixed(3)} ~ ${_safeDouble(widget.summary['max']).toStringAsFixed(3)}${estimatedRate == null ? '' : ' | 节律 ${estimatedRate.toStringAsFixed(1)} BPM'}',
            ),
            const SizedBox(height: 8),
            Text(
              widget.enableHoverInspect
                  ? (_hoverInfo == null
                      ? '暂停回看中：鼠标移动到波形上可查看当前点位数值。'
                      : '游标值 ${_hoverInfo!.sample.value.toStringAsFixed(4)} ${widget.channel.unit} @ ${_formatTimestamp(_hoverInfo!.sample.timestampMs)}')
                  : '实时滚动中：已关闭鼠标取值以降低绘图压力。',
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final width = constraints.maxWidth;
                  const height = 220.0;
                  return MouseRegion(
                    onExit: (_) {
                      if (_hoverInfo != null) {
                        setState(() {
                          _hoverInfo = null;
                        });
                      }
                    },
                    onHover: (event) {
                      if (!widget.enableHoverInspect) {
                        return;
                      }
                      final nowMs = DateTime.now().millisecondsSinceEpoch;
                      if (nowMs - _lastHoverUpdateMs < 120) {
                        return;
                      }
                      _lastHoverUpdateMs = nowMs;
                      final nextHover = _resolveHover(
                        localPosition: event.localPosition,
                        width: width,
                        height: height,
                      );
                      if (_hoverEquals(_hoverInfo, nextHover)) {
                        return;
                      }
                      setState(() {
                        _hoverInfo = nextHover;
                      });
                    },
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                            painter: _WaveformPainter(
                              points: widget.points,
                              viewport: viewport,
                              color: colorFromHex(widget.channel.colorHex),
                              gain: widget.gain,
                              secondsPerScreen: widget.secondsPerScreen,
                              anchorTimestampMs: widget.anchorTimestampMs,
                              showLabels: widget.enableHoverInspect,
                            ),
                            child: widget.points.isEmpty
                                ? const Center(child: Text('当前窗口暂无数据'))
                                : const SizedBox.expand(),
                          ),
                          ),
                        ),
                        if (_hoverInfo != null) ...<Widget>[
                          Positioned(
                            left: _hoverInfo!.localDx - 0.5,
                            top: 0,
                            bottom: 0,
                            child: Container(width: 1, color: const Color(0xFF51606B)),
                          ),
                          Positioned(
                            left: _hoverInfo!.localDx - 4,
                            top: _hoverInfo!.localDy - 4,
                            child: IgnorePointer(
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: colorFromHex(widget.channel.colorHex),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: _bubbleLeft(_hoverInfo!, width),
                            top: _bubbleTop(_hoverInfo!, height),
                            child: IgnorePointer(
                              child: Container(
                                width: 156,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF132A13),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: DefaultTextStyle(
                                  style: const TextStyle(color: Colors.white, fontSize: 11),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(_formatTimestamp(_hoverInfo!.sample.timestampMs)),
                                      const SizedBox(height: 4),
                                      Text('${_hoverInfo!.sample.value.toStringAsFixed(4)} ${widget.channel.unit}'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  HoverSampleInfo? _resolveHover({required Offset localPosition, required double width, required double height}) {
    if (widget.points.isEmpty || width <= 0 || height <= 0) {
      return null;
    }

    final windowMs = (widget.secondsPerScreen * 1000).round();
    final startMs = widget.anchorTimestampMs - windowMs;
    final chartWidth = math.max(1.0, width - _waveformYAxisWidth);
    final clampedDx = (localPosition.dx - _waveformYAxisWidth).clamp(
      0.0,
      chartWidth,
    );
    final targetMs = startMs + (clampedDx / chartWidth * windowMs).round();
    final sample = _nearestSample(widget.points, targetMs);
    final viewport = _stableViewport ?? _targetViewport();
    final sampleDx = _waveformYAxisWidth +
        ((sample.timestampMs - startMs) / windowMs).clamp(0.0, 1.0) * chartWidth;
    final sampleDy = viewport.dyForValue(value: sample.value, gain: widget.gain, height: height);

    return HoverSampleInfo(sample: sample, localDx: sampleDx, localDy: sampleDy);
  }

  _WaveformViewport _targetViewport() {
    return _WaveformViewport.fromBounds(
      minValue: widget.minValue,
      maxValue: widget.maxValue,
    );
  }

  _WaveformViewport _resolveStableViewport(_WaveformViewport target) {
    final previous = _stableViewport;
    if (previous == null || widget.points.isEmpty) {
      _stableViewport = target;
      return target;
    }

    final previousMin = previous.minLabel;
    final previousMax = previous.maxLabel;
    final targetMin = target.minLabel;
    final targetMax = target.maxLabel;
    final nextMin = targetMin < previousMin
        ? targetMin
        : previousMin + (targetMin - previousMin) * 0.08;
    final nextMax = targetMax > previousMax
        ? targetMax
        : previousMax + (targetMax - previousMax) * 0.08;
    _stableViewport = _WaveformViewport.fromLabelBounds(
      minLabel: nextMin,
      maxLabel: nextMax,
    );
    return _stableViewport!;
  }

  SamplePoint _nearestSample(List<SamplePoint> points, int targetTimestampMs) {
    if (points.length == 1) {
      return points.first;
    }
    var low = 0;
    var high = points.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final current = points[mid].timestampMs;
      if (current == targetTimestampMs) {
        return points[mid];
      }
      if (current < targetTimestampMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (low >= points.length) {
      return points.last;
    }
    if (high < 0) {
      return points.first;
    }

    final lowPoint = points[low];
    final highPoint = points[high];
    return (lowPoint.timestampMs - targetTimestampMs).abs() < (highPoint.timestampMs - targetTimestampMs).abs() ? lowPoint : highPoint;
  }
  bool _hoverEquals(HoverSampleInfo? a, HoverSampleInfo? b) {
    if (a == null || b == null) {
      return a == b;
    }
    return a.sample.timestampMs == b.sample.timestampMs;
  }

  double _bubbleLeft(HoverSampleInfo info, double width) {
    return math.min(math.max(8, info.localDx + 12), math.max(8, width - 164));
  }

  double _bubbleTop(HoverSampleInfo info, double height) {
    final preferred = info.localDy < 72 ? info.localDy + 12 : info.localDy - 62;
    return math.min(math.max(8, preferred), math.max(8, height - 64));
  }

  String _formatTimestamp(int timestampMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final mmm = time.millisecond.toString().padLeft(3, '0');
    return '$hh:$mm:$ss.$mmm';
  }

  double _safeDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }

  double? _safeNullableDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.points,
    required this.viewport,
    required this.color,
    required this.gain,
    required this.secondsPerScreen,
    required this.anchorTimestampMs,
    required this.showLabels,
  });

  final List<SamplePoint> points;
  final _WaveformViewport viewport;
  final Color color;
  final double gain;
  final double secondsPerScreen;
  final int anchorTimestampMs;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = const Color(0xFFF9FBFA);
    final gridPaint = Paint()
      ..color = const Color(0xFFD8E2DC)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = const Color(0xFFA9BBB2)
      ..strokeWidth = 1.2;
    final midlinePaint = Paint()
      ..color = const Color(0xFFB8C7C0)
      ..strokeWidth = 1.4;
    final signalPaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    canvas.drawRRect(rrect, backgroundPaint);
    canvas.save();
    canvas.clipRRect(rrect);

    const verticalDivisions = 8;
    const horizontalDivisions = 6;
    final chartLeft = _waveformYAxisWidth;
    final chartWidth = math.max(1.0, size.width - chartLeft);
    final chartRight = chartLeft + chartWidth;

    canvas.drawLine(
      Offset(chartLeft, 0),
      Offset(chartLeft, size.height),
      axisPaint,
    );

    for (var i = 0; i <= verticalDivisions; i++) {
      final dx = chartLeft + chartWidth * i / verticalDivisions;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), gridPaint);
      final secondsLeft = secondsPerScreen - secondsPerScreen * i / verticalDivisions;
      final labelDx = i == verticalDivisions
          ? dx - 34
          : dx + 4;
      if (showLabels) {
        _drawLabel(
          canvas,
          size,
          text: '-${secondsLeft.toStringAsFixed(1)}s',
          offset: Offset(labelDx, size.height - 18),
        );
      }
    }

    for (var j = 0; j <= horizontalDivisions; j++) {
      final dy = size.height * j / horizontalDivisions;
      canvas.drawLine(Offset(chartLeft, dy), Offset(chartRight, dy), gridPaint);
    }

    if (points.length < 2) {
      canvas.restore();
      return;
    }

    canvas.drawLine(
      Offset(chartLeft, size.height / 2),
      Offset(chartRight, size.height / 2),
      midlinePaint,
    );
    for (var j = 0; j <= horizontalDivisions; j++) {
      final ratio = 1 - (j / horizontalDivisions);
      final labelValue = viewport.minLabel +
          (viewport.maxLabel - viewport.minLabel) * ratio;
      final dy = size.height * j / horizontalDivisions;
      canvas.drawLine(
        Offset(chartLeft - 6, dy),
        Offset(chartLeft, dy),
        axisPaint,
      );
      if (showLabels) {
        _drawLabel(
          canvas,
          size,
          text: labelValue.toStringAsFixed(2),
          offset: Offset(6, (dy - 7).clamp(2.0, size.height - 18)),
        );
      }
    }

    final windowMs = (secondsPerScreen * 1000).round();
    final startMs = anchorTimestampMs - windowMs;
    final renderPoints = _downsamplePoints(
      points,
      maxPoints: math.max(96, size.width.round() * 2),
    );
    final offsets = renderPoints
        .map(
          (SamplePoint point) => Offset(
            chartLeft + ((point.timestampMs - startMs) / windowMs) * chartWidth,
            viewport.dyForValue(
              value: point.value,
              gain: gain,
              height: size.height,
            ),
          ),
        )
        .toList(growable: false);
    final path = Path();
    final gapThresholdMs = math.max(250, math.min(1200, windowMs ~/ 10));
    var segmentStart = 0;
    for (var index = 1; index <= renderPoints.length; index++) {
      final isEnd = index == renderPoints.length;
      final hasGap = !isEnd &&
          renderPoints[index].timestampMs - renderPoints[index - 1].timestampMs >
              gapThresholdMs;
      if (isEnd || hasGap) {
        _appendPathSegment(path, offsets, segmentStart, index);
        segmentStart = index;
      }
    }
    canvas.drawPath(path, signalPaint);
    canvas.restore();
  }

  void _appendPathSegment(
    Path path,
    List<Offset> offsets,
    int start,
    int endExclusive,
  ) {
    if (endExclusive <= start) {
      return;
    }
    path.moveTo(offsets[start].dx, offsets[start].dy);
    if (endExclusive - start == 1) {
      return;
    }
    if (endExclusive - start == 2) {
      final last = offsets[endExclusive - 1];
      path.lineTo(last.dx, last.dy);
      return;
    }
    for (var index = start + 1; index < endExclusive; index++) {
      final current = offsets[index];
      path.lineTo(current.dx, current.dy);
    }
  }

  List<SamplePoint> _downsamplePoints(
    List<SamplePoint> source, {
    required int maxPoints,
  }) {
    if (source.length <= maxPoints) {
      return source;
    }

    final chunkSize = math.max(1, (source.length / maxPoints).ceil());
    final reduced = <SamplePoint>[];
    for (var start = 0; start < source.length; start += chunkSize) {
      final end = math.min(source.length, start + chunkSize);
      var minPoint = source[start];
      var maxPoint = source[start];
      for (var index = start + 1; index < end; index++) {
        final point = source[index];
        if (point.value < minPoint.value) {
          minPoint = point;
        }
        if (point.value > maxPoint.value) {
          maxPoint = point;
        }
      }
      _appendUnique(reduced, source[start]);
      if (minPoint.timestampMs <= maxPoint.timestampMs) {
        _appendUnique(reduced, minPoint);
        _appendUnique(reduced, maxPoint);
      } else {
        _appendUnique(reduced, maxPoint);
        _appendUnique(reduced, minPoint);
      }
      _appendUnique(reduced, source[end - 1]);
    }
    return reduced;
  }

  void _appendUnique(List<SamplePoint> target, SamplePoint point) {
    if (target.isNotEmpty &&
        target.last.timestampMs == point.timestampMs &&
        target.last.value == point.value) {
      return;
    }
    target.add(point);
  }

  void _drawLabel(Canvas canvas, Size size, {required String text, required Offset offset}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 10, color: Color(0xFF51606B))),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(0, size.width - offset.dx));
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.viewport.center != viewport.center ||
        oldDelegate.viewport.halfRange != viewport.halfRange ||
        oldDelegate.gain != gain ||
        oldDelegate.anchorTimestampMs != anchorTimestampMs ||
        oldDelegate.secondsPerScreen != secondsPerScreen ||
        oldDelegate.showLabels != showLabels ||
        oldDelegate.color != color;
  }
}

class _WaveformViewport {
  const _WaveformViewport({required this.center, required this.halfRange});

  final double center;
  final double halfRange;

  factory _WaveformViewport.fromBounds({
    required double minValue,
    required double maxValue,
  }) {
    if (minValue == 0 && maxValue == 0) {
      return const _WaveformViewport(center: 0, halfRange: 1);
    }
    final center = (minValue + maxValue) / 2;
    var halfRange = (maxValue - minValue) / 2;
    if (halfRange.abs() < 0.0001) {
      halfRange = 1;
    }
    return _WaveformViewport(center: center, halfRange: halfRange * 1.1);
  }

  factory _WaveformViewport.fromLabelBounds({
    required double minLabel,
    required double maxLabel,
  }) {
    final center = (minLabel + maxLabel) / 2;
    var halfRange = (maxLabel - minLabel) / 2;
    if (halfRange.abs() < 0.0001) {
      halfRange = 1;
    }
    return _WaveformViewport(center: center, halfRange: halfRange);
  }

  double get maxLabel => center + halfRange;
  double get minLabel => center - halfRange;

  double dyForValue({required double value, required double gain, required double height}) {
    final adjusted = center + (value - center) * gain;
    final normalized = ((adjusted - center) / halfRange).clamp(-1.0, 1.0);
    return height / 2 - normalized * (height / 2);
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final MedicalReport report;

  Color _riskColor(String? level) {
    switch (level) {
      case 'high':
        return const Color(0xFFE63946);
      case 'medium':
        return const Color(0xFFF4A261);
      case 'low':
        return const Color(0xFF2A9D8F);
      default:
        return const Color(0xFF8D99AE);
    }
  }

  String _riskLabel(String? level) {
    switch (level) {
      case 'high':
        return '高风险';
      case 'medium':
        return '中风险';
      case 'low':
        return '低风险';
      default:
        return '未评估';
    }
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'high':
        return const Color(0xFFE63946);
      case 'medium':
        return const Color(0xFFF4A261);
      case 'low':
        return const Color(0xFF457B9D);
      default:
        return const Color(0xFF8D99AE);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isRuleFallback = report.summary.contains('未启用大模型');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('云端报告', style: Theme.of(context).textTheme.titleMedium),
                ),
                if (report.riskLevel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _riskColor(report.riskLevel).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: _riskColor(report.riskLevel)),
                    ),
                    child: Text(
                      _riskLabel(report.riskLevel),
                      style: TextStyle(
                        color: _riskColor(report.riskLevel),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('会话 ${report.sessionId}', style: const TextStyle(fontSize: 12, color: Color(0xFF8D99AE))),
            Text('生成时间 ${report.generatedAt}', style: const TextStyle(fontSize: 12, color: Color(0xFF8D99AE))),
            if (report.confidence != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '分析置信度 ${(report.confidence! * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8D99AE)),
              ),
            ],
            if (isRuleFallback) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3CD),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFFD166)),
                ),
                child: const Text(
                  '未启用大模型，降级输出',
                  style: TextStyle(fontSize: 12, color: Color(0xFF856404)),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(report.summary),
            const SizedBox(height: 16),
            Text('主要发现', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final ReportFinding finding in report.findings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFDCE3EA)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6, top: 1),
                            decoration: BoxDecoration(
                              color: _severityColor(finding.severity),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(child: Text(finding.title, style: const TextStyle(fontWeight: FontWeight.w500))),
                          Text(
                            finding.severity,
                            style: TextStyle(fontSize: 11, color: _severityColor(finding.severity)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(finding.detail, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ),
            Text('建议', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final String item in report.recommendations)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $item'),
              ),
          ],
        ),
      ),
    );
  }
}

