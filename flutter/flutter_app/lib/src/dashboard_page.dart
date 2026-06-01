import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'monitor_controller.dart';

const double _waveformYAxisWidth = 48;

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

  bool _advancedConnectionOpen = false;
  bool _detailStatsOpen = false;
  bool _diagnosticsLogOpen = false;

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
      body: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? _) => Column(
          children: <Widget>[
            _buildTopBar(context),
            if (_controller.agentStatus.hasActiveAlert) _buildHighRiskAlertBar(context),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final isCompact = constraints.maxWidth < 1100;
                  if (isCompact) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: <Widget>[
                          _buildMetricsBar(context),
                          const SizedBox(height: 12),
                          AnimatedBuilder(
                            animation: _waveformListenable,
                            builder: (_, __) => _buildWaveformArea(context),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: _buildControlPanel(context),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ),
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildControlPanel(context),
                      Expanded(
                        child: AnimatedBuilder(
                          animation: _waveformListenable,
                          builder: (_, __) => Column(
                            children: <Widget>[
                              _buildMetricsBar(context),
                              const SizedBox(height: 12),
                              Expanded(child: _buildWaveformArea(context)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top status bar ──────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF0B6E4F),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.monitor_heart_outlined, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          const Text(
            '心肺功能监测控制台',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          AnimatedBuilder(
            animation: _controller,
            builder: (_, __) => _StatusBadge(status: _controller.status),
          ),
        ],
      ),
    );
  }

  // ── High-risk alert bar ─────────────────────────────────────────

  Widget _buildHighRiskAlertBar(BuildContext context) {
    final agent = _controller.agentStatus;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFE63946),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '高风险预警：${agent.summary}（辅助预警，不构成医疗诊断）',
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _showAgentDetailDialog(context),
            style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('查看依据', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => _controller.acknowledgeAgentAlert(),
            style: TextButton.styleFrom(foregroundColor: Colors.white70, padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('确认已知晓', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── Key metrics bar ─────────────────────────────────────────────

  Widget _buildMetricsBar(BuildContext context) {
    final physio = _controller.localAnalysis.physio;
    final analysis = _controller.localAnalysis;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD0D8D3).withValues(alpha: 0.5)),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          if (physio.heartRateBpm != null)
            _VitalChip(
              icon: Icons.favorite,
              color: const Color(0xFFE63946),
              label: 'HR',
              value: physio.heartRateBpm!.toStringAsFixed(0),
              unit: 'BPM',
            ),
          if (physio.spo2Percent != null)
            _VitalChip(
              icon: Icons.air,
              color: const Color(0xFF2A9D8F),
              label: 'SpO₂',
              value: physio.spo2Percent!.toStringAsFixed(0),
              unit: '%',
            ),
          _VitalChip(
            icon: Icons.analytics_outlined,
            color: const Color(0xFF457B9D),
            label: '质量',
            value: (analysis.meanQuality * 100).toStringAsFixed(0),
            unit: '%',
          ),
          _VitalChip(
            icon: Icons.upload_outlined,
            color: const Color(0xFF8D99AE),
            label: '分段',
            value: '${_controller.uploadedSegmentCount}',
            unit: '段',
          ),
          if (_controller.isConnected)
            _VitalChip(
              icon: Icons.timer_outlined,
              color: _controller.transportStats.isNotEmpty &&
                      _controller.transportStats.first.lastPublishLatencyMs > 200
                  ? const Color(0xFFF4A261)
                  : const Color(0xFF2A9D8F),
              label: '延迟',
              value: _controller.transportStats.isNotEmpty
                  ? '${_controller.transportStats.first.lastPublishLatencyMs}'
                  : '-',
              unit: 'ms',
            ),
        ],
      ),
    );
  }

  // ── Waveform area ───────────────────────────────────────────────

  Widget _buildWaveformArea(BuildContext context) {
    final visibleChannels = _controller.visibleChannels;
    if (visibleChannels.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D1B2A),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.monitor_heart_outlined, size: 48, color: Colors.teal[300]!.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                '暂无可显示的通道',
                style: TextStyle(color: Colors.teal[200], fontSize: 14),
              ),
              const SizedBox(height: 4),
              Text(
                '请先连接 MQTT / 蓝牙设备，或导入回放文件',
                style: TextStyle(color: Colors.teal[200]!.withValues(alpha: 0.6), fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: visibleChannels.length + (_controller.report != null ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 8),
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
    );
  }

  // ── Control sidebar (unified single-panel) ──────────────────────

  static const _kSidebarWidth = 348.0;

  Widget _buildControlPanel(BuildContext context) {
    return Container(
      width: _kSidebarWidth,
      decoration: const BoxDecoration(
        color: Color(0xFFF4F7F5),
        border: Border(right: BorderSide(color: Color(0xFFD0D8D3), width: 1)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildConnectionBlock(context),
            _SidebarDivider(),
            _buildDisplayControlBlock(context),
            _SidebarDivider(),
            _buildChannelBlock(context),
            _SidebarDivider(),
            _buildLocalSummaryBlock(context),
            _SidebarDivider(),
            _buildSmartAnalysisBlock(context),
            _SidebarDivider(),
            _buildDiagnosticsBlock(context),
          ],
        ),
      ),
    );
  }

  // ── 1. 采集与连接 ──────────────────────────────────────────────

  Widget _buildConnectionBlock(BuildContext context) {
    return _SidebarSection(
      icon: Icons.link,
      title: '采集与连接',
      children: <Widget>[
        _buildSourceSegmentedControl(context),
        const SizedBox(height: 8),
        _buildTextField('用户姓名 / 编号', _userNameController, (String value) {
          _controller.updateUserName(value);
        }),
        if (_controller.mode == DataSourceMode.wifi) ...<Widget>[
          const SizedBox(height: 6),
          _buildTextField('Broker Host', _hostController, (String value) {
            _controller.updateMqttConfig(host: value);
          }),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: _buildTextField('端口', _portController, (String value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null) _controller.updateMqttConfig(port: parsed);
                }),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildTextField('Path', _pathController, (String value) {
                  _controller.updateMqttConfig(path: value);
                }),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _buildTextField('设备 ID', _deviceIdController, (String value) {
            _controller.updateMqttConfig(deviceId: value);
          }),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('高级连接设置', style: Theme.of(context).textTheme.bodySmall),
            initiallyExpanded: _advancedConnectionOpen,
            onExpansionChanged: (v) => setState(() => _advancedConnectionOpen = v),
            children: <Widget>[
              const SizedBox(height: 2),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _buildTextField('用户名', _usernameController, (String value) {
                      _controller.updateMqttConfig(username: value);
                    }),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _buildTextField('密码', _passwordController, (String value) {
                      _controller.updateMqttConfig(password: value);
                    }, obscureText: true),
                  ),
                ],
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('启用 TLS / WSS'),
                value: _controller.mqttConfig.useTls,
                onChanged: (bool value) => _controller.updateMqttConfig(useTls: value),
              ),
            ],
          ),
        ],
        if (_controller.mode == DataSourceMode.file) ...<Widget>[
          const SizedBox(height: 6),
          FilledButton.tonalIcon(
            onPressed: _controller.pickReplayFile,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('选择 CSV / JSON'),
          ),
          const SizedBox(height: 4),
          Text(
            _controller.hasReplayFile ? '当前: ${_controller.replayFileName}' : '未选择回放文件',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (_controller.mode == DataSourceMode.bluetooth) ...<Widget>[
          const SizedBox(height: 6),
          _buildTextField('设备名前缀', _bleNamePrefixController, (String value) {
            _controller.updateBluetoothConfig(deviceNamePrefix: value);
          }),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('高级 BLE 设置', style: Theme.of(context).textTheme.bodySmall),
            children: <Widget>[
              const SizedBox(height: 2),
              _buildTextField('服务 UUID', _bleServiceController, (String value) {
                _controller.updateBluetoothConfig(serviceUuid: value);
              }),
              const SizedBox(height: 6),
              _buildTextField('通知特征 UUID', _bleNotifyController, (String value) {
                _controller.updateBluetoothConfig(notifyCharacteristicUuid: value);
              }),
              const SizedBox(height: 6),
              _buildTextField('控制特征 UUID', _bleControlController, (String value) {
                _controller.updateBluetoothConfig(controlCharacteristicUuid: value);
              }),
            ],
          ),
        ],
        const SizedBox(height: 8),
        _CompactStatusRow(
          items: <_StatusItem>[
            _StatusItem('已上传', '${_controller.uploadedSegmentCount}'),
            _StatusItem('待上传', '${_controller.pendingSegmentUploadCount}'),
            if (_controller.failedSegmentUploadCount > 0)
              _StatusItem('失败', '${_controller.failedSegmentUploadCount}', highlight: true),
          ],
        ),
        if (_controller.latestSegment != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '最近分段: #${_controller.latestSegment!.segmentIndex} / ${_controller.latestSegment!.sampleCount} 点',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 38,
          child: FilledButton.icon(
            onPressed: _controller.isConnected
                ? _controller.disconnect
                : () {
                    _syncConnectionFieldsToController();
                    _controller.connect();
                  },
            icon: Icon(_controller.isConnected ? Icons.stop_circle_outlined : Icons.play_arrow, size: 18),
            label: Text(_controller.isConnected ? '断开 / 停止' : '连接 / 开始'),
          ),
        ),
      ],
    );
  }

  Widget _buildSourceSegmentedControl(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EDEA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: DataSourceMode.values.map((DataSourceMode mode) {
          final selected = _controller.mode == mode;
          return Expanded(
            child: GestureDetector(
              onTap: () => _controller.setMode(mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: selected
                      ? <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
                      : null,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      mode == DataSourceMode.wifi
                          ? Icons.wifi
                          : mode == DataSourceMode.bluetooth
                              ? Icons.bluetooth
                              : Icons.upload_file_outlined,
                      size: 14,
                      color: selected ? const Color(0xFF0B6E4F) : const Color(0xFF8D99AE),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      mode.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        color: selected ? const Color(0xFF0B6E4F) : const Color(0xFF8D99AE),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── 2. 显示控制 ────────────────────────────────────────────────

  Widget _buildDisplayControlBlock(BuildContext context) {
    final maxOffset = _controller.maxHistoryOffsetSeconds;
    final historySliderMax = maxOffset <= 0 ? 1.0 : maxOffset;
    final historySliderValue = _controller.isPaused
        ? _controller.historyOffsetSeconds.clamp(0.0, historySliderMax)
        : 0.0;

    return _SidebarSection(
      icon: Icons.tune,
      title: '显示控制',
      children: <Widget>[
        Row(
          children: <Widget>[
            SizedBox(
              width: 34,
              height: 34,
              child: IconButton.filled(
                onPressed: _controller.togglePause,
                icon: Icon(_controller.isPaused ? Icons.play_arrow : Icons.pause, size: 16),
                style: IconButton.styleFrom(
                  backgroundColor: _controller.isPaused ? const Color(0xFFF4A261) : const Color(0xFF0B6E4F),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
                tooltip: _controller.isPaused ? '继续播放' : '暂停回看',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _controller.isPaused ? '已暂停 · 可回滚' : '实时播放中',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _controller.isPaused ? const Color(0xFFF4A261) : const Color(0xFF2A9D8F),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _CompactSliderRow(
          label: '时间窗',
          value: _controller.secondsPerScreen,
          min: 2,
          max: 20,
          divisions: 18,
          unit: 's',
          onChanged: _controller.setSecondsPerScreen,
        ),
        _CompactSliderRow(
          label: '延迟',
          value: _controller.liveDisplayLagSeconds,
          min: 0,
          max: 6,
          divisions: 24,
          unit: 's',
          onChanged: _controller.setLiveDisplayLagSeconds,
        ),
        if (_controller.isPaused)
          _CompactSliderRow(
            label: '回滚',
            value: historySliderValue,
            min: 0,
            max: historySliderMax,
            unit: 's',
            onChanged: _controller.canRollbackHistory ? _controller.setHistoryOffsetSeconds : null,
          ),
        _CompactSliderRow(
          label: '增益',
          value: _controller.gain,
          min: 0.5,
          max: 4,
          divisions: 14,
          unit: 'x',
          onChanged: _controller.setGain,
        ),
      ],
    );
  }

  // ── 3. 通道 ────────────────────────────────────────────────────

  Widget _buildChannelBlock(BuildContext context) {
    final catalog = _controller.channelCatalog;
    if (catalog.isEmpty) {
      return _SidebarSection(
        icon: Icons.graphic_eq,
        title: '通道',
        children: <Widget>[
          Text('尚未收到通道目录，请先连接设备或导入文件', style: Theme.of(context).textTheme.bodySmall),
        ],
      );
    }
    final mainChannels = catalog.where((ChannelDescriptor c) => _isMainChannel(c.key)).toList();
    final otherChannels = catalog.where((ChannelDescriptor c) => !_isMainChannel(c.key)).toList();

    return _SidebarSection(
      icon: Icons.graphic_eq,
      title: '通道',
      children: <Widget>[
        for (final ChannelDescriptor channel in mainChannels)
          _ChannelToggle(
            channel: channel,
            onChanged: (bool v) => _controller.toggleChannel(channel.key, v),
          ),
        if (otherChannels.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('其他通道 (${otherChannels.length})', style: Theme.of(context).textTheme.bodySmall),
            children: otherChannels.map((ChannelDescriptor channel) => _ChannelToggle(
              channel: channel,
              onChanged: (bool v) => _controller.toggleChannel(channel.key, v),
            )).toList(),
          ),
      ],
    );
  }

  // ── 4. 本地摘要 ────────────────────────────────────────────────

  bool _isMainChannel(String key) =>
      key == 'ecg_filtered' || key == 'ecg' || key == 'ppg_ir_filtered' ||
      key == 'ppg_ir' || key == 'ppg_red_filtered' || key == 'ppg_red';

  Widget _buildLocalSummaryBlock(BuildContext context) {
    final analysis = _controller.localAnalysis;
    final physio = analysis.physio;
    return _SidebarSection(
      icon: Icons.analytics_outlined,
      title: '本地摘要',
      children: <Widget>[
        Row(
          children: <Widget>[
            _MetricChip(label: '通道', value: '${analysis.activeChannels}'),
            const SizedBox(width: 4),
            _MetricChip(label: '时长', value: '${analysis.durationSeconds.toStringAsFixed(1)} s'),
            const SizedBox(width: 4),
            _MetricChip(label: '质量', value: '${(analysis.meanQuality * 100).toStringAsFixed(0)} %'),
          ],
        ),
        if (physio.hasAny) ...<Widget>[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              if (physio.heartRateBpm != null) _MetricChip(label: 'HR', value: '${physio.heartRateBpm!.toStringAsFixed(1)} BPM'),
              if (physio.spo2Percent != null) _MetricChip(label: 'SpO₂', value: '${physio.spo2Percent!.toStringAsFixed(1)} %'),
              if (physio.respiratoryRateBpm != null) _MetricChip(label: '呼吸', value: '${physio.respiratoryRateBpm!.toStringAsFixed(1)} /min'),
              if (physio.hrvRmssd != null) _MetricChip(label: 'RMSSD', value: '${physio.hrvRmssd!.toStringAsFixed(1)} ms'),
              if (physio.temperatureCelsius != null) _MetricChip(label: '体温', value: '${physio.temperatureCelsius!.toStringAsFixed(2)} °C'),
            ],
          ),
        ],
        if (analysis.findings.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('查看详细统计', style: Theme.of(context).textTheme.bodySmall),
            initiallyExpanded: _detailStatsOpen,
            onExpansionChanged: (v) => setState(() => _detailStatsOpen = v),
            children: <Widget>[
              ...analysis.findings.take(4).map((String item) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: _FindingTile(text: item),
              )),
            ],
          ),
        ],
      ],
    );
  }

  // ── 5. 智能分析（云端 + Agent 合并）────────────────────────────

  Widget _buildSmartAnalysisBlock(BuildContext context) {
    final agent = _controller.agentStatus;
    final agentEnabled = agent.state != AgentState.idle || _controller.isConnected;

    return _SidebarSection(
      icon: Icons.psychology_alt_outlined,
      title: '智能分析',
      children: <Widget>[
        _buildTextField('云端地址', _cloudController, (String value) {
          _controller.updateCloudBaseUrl(value);
        }),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _controller.uploadAndAnalyze,
                icon: const Icon(Icons.cloud_upload_outlined, size: 14),
                label: const Text('上传并分析', style: TextStyle(fontSize: 12)),
              ),
            ),
            if (_controller.latestSegment != null) ...<Widget>[
              const SizedBox(width: 6),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _controller.analyzeLatestSegment,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 14),
                  label: const Text('AI 分析 20s', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ),
        if (_controller.uploadTask != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('上传: ${_controller.uploadTask!.status}', style: Theme.of(context).textTheme.bodySmall),
          ),
        if (_controller.analysisJob != null)
          Text('分析: ${_controller.analysisJob!.status}', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        _SidebarSubDivider(),
        Row(
          children: <Widget>[
            Icon(Icons.smart_toy_outlined, size: 14, color: _agentStateColor(agent.state)),
            const SizedBox(width: 4),
            Text('长期监测 Agent', style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _agentStateColor(agent.state).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                agent.stateLabel,
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _agentStateColor(agent.state)),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 36,
              height: 24,
              child: Switch(
                value: agentEnabled,
                onChanged: (bool v) => _controller.toggleAgentAutoAnalyze(v),
              ),
            ),
          ],
        ),
        if (agent.lastAnalysisTime != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('最近分析: ${_formatDateTime(agent.lastAnalysisTime!)}', style: Theme.of(context).textTheme.bodySmall),
          ),
        if (agent.riskLevel != null)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _riskColor(agent.riskLevel).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    agent.riskLabel,
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: _riskColor(agent.riskLevel)),
                  ),
                ),
                if (agent.confidence != null) ...<Widget>[
                  const SizedBox(width: 6),
                  Text('置信度 ${(agent.confidence! * 100).toStringAsFixed(0)}%', style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        if (agent.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(agent.summary, style: Theme.of(context).textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        if (agent.isHighRisk) ...<Widget>[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFEDED),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE63946).withValues(alpha: 0.3)),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFE63946)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text('高风险预警', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFE63946))),
                ),
                TextButton(
                  onPressed: () => _showAgentDetailDialog(context),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text('详情', style: TextStyle(fontSize: 10)),
                ),
                TextButton(
                  onPressed: () => _controller.acknowledgeAgentAlert(),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text('知晓', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
          ),
        ],
        if (agent.notificationText.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            shape: const Border(),
            collapsedShape: const Border(),
            title: Text('亲属通知文案预览', style: Theme.of(context).textTheme.bodySmall),
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8F0),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE8C8A0)),
                ),
                child: Text(agent.notificationText, style: const TextStyle(fontSize: 10, height: 1.4)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '辅助预警，不构成医疗诊断',
          style: TextStyle(fontSize: 9, color: Colors.grey[400]),
        ),
      ],
    );
  }

  // ── 6. 诊断日志（默认折叠）─────────────────────────────────────

  Widget _buildDiagnosticsBlock(BuildContext context) {
    final stats = _controller.transportStats;
    final events = _controller.events;
    final hasErrors = stats.any((TransportStats s) =>
        s.publishFailCount > 0 || s.crcErrorCount > 0 || s.decodeErrorCount > 0) ||
        events.isNotEmpty && events.first.contains('失败');

    return _SidebarSection(
      icon: Icons.terminal,
      title: '诊断日志',
      trailing: hasErrors
          ? Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(color: Color(0xFFF4A261), shape: BoxShape.circle),
            )
          : null,
      children: <Widget>[
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: _diagnosticsLogOpen,
          onExpansionChanged: (v) => setState(() => _diagnosticsLogOpen = v),
          title: Text(
            hasErrors ? '有异常，点击展开' : '点击展开',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          children: <Widget>[
            if (stats.isNotEmpty) ...<Widget>[
              for (final TransportStats item in stats) ...<Widget>[
                Text('${item.source}${item.deviceId.isEmpty ? '' : ' · ${item.deviceId}'}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 4,
                  runSpacing: 3,
                  children: <Widget>[
                    _MetricChip(label: 'pub fail', value: '${item.publishFailCount}'),
                    _MetricChip(label: 'crc', value: '${item.crcErrorCount}'),
                    _MetricChip(label: 'latency', value: '${item.lastPublishLatencyMs} ms'),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ],
            if (events.isEmpty)
              Text('尚无日志', style: Theme.of(context).textTheme.bodySmall)
            else
              ...events.take(8).map((String item) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(item, style: const TextStyle(fontSize: 10, height: 1.3, color: Color(0xFF6B7C72))),
              )),
          ],
        ),
      ],
    );
  }

  void _showAgentDetailDialog(BuildContext context) {
    final agent = _controller.agentStatus;
    final report = _controller.report;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Agent 分析依据'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (agent.riskLevel != null)
                Text('风险等级: ${agent.riskLabel}'),
              if (agent.confidence != null)
                Text('置信度: ${(agent.confidence! * 100).toStringAsFixed(0)}%'),
              const SizedBox(height: 8),
              if (agent.summary.isNotEmpty) Text(agent.summary),
              if (report != null && report.findings.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                const Text('主要发现:', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final f in report.findings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('· ${f.title}: ${f.detail}'),
                  ),
              ],
              const SizedBox(height: 12),
              const Text('辅助预警，不构成医疗诊断。', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12)),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Color _agentStateColor(AgentState state) {
    switch (state) {
      case AgentState.idle:
        return const Color(0xFF8D99AE);
      case AgentState.analyzing:
        return const Color(0xFF457B9D);
      case AgentState.normal:
        return const Color(0xFF2A9D8F);
      case AgentState.warning:
        return const Color(0xFFF4A261);
      case AgentState.highRisk:
        return const Color(0xFFE63946);
      case AgentState.error:
        return const Color(0xFFE63946);
    }
  }

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

  // ── Helpers ─────────────────────────────────────────────────────

  Widget _buildTextField(String label, TextEditingController controller, ValueChanged<String> onChanged, {bool obscureText = false}) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
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

  String _formatDateTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}

// ── Sidebar helper widgets ─────────────────────────────────────────

class _SidebarSection extends StatelessWidget {
  const _SidebarSection({
    required this.icon,
    required this.title,
    this.trailing,
    required this.children,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 14, color: const Color(0xFF0B6E4F)),
            const SizedBox(width: 6),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

class _SidebarDivider extends StatelessWidget {
  const _SidebarDivider();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Divider(height: 1, color: const Color(0xFFD0D8D3).withValues(alpha: 0.5)),
    );
  }
}

class _SidebarSubDivider extends StatelessWidget {
  const _SidebarSubDivider();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Divider(height: 1, color: const Color(0xFFD0D8D3).withValues(alpha: 0.3)),
    );
  }
}

class _CompactSliderRow extends StatelessWidget {
  const _CompactSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.unit,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String unit;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 56,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${value.toStringAsFixed(1)} $unit',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _StatusItem {
  const _StatusItem(this.label, this.value, {this.highlight = false});

  final String label;
  final String value;
  final bool highlight;
}

class _CompactStatusRow extends StatelessWidget {
  const _CompactStatusRow({required this.items});

  final List<_StatusItem> items;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items.map((_StatusItem item) {
        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${item.label} ',
                style: TextStyle(
                  fontSize: 11,
                  color: item.highlight ? const Color(0xFFE63946) : const Color(0xFF6B7C72),
                ),
              ),
              Text(
                item.value,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: item.highlight ? const Color(0xFFE63946) : const Color(0xFF2A3B32),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Private widget classes ─────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final AdapterStatus status;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (status.state) {
      case AdapterState.streaming:
        bg = Colors.white.withValues(alpha: 0.2);
        fg = Colors.white;
        break;
      case AdapterState.connected:
        bg = Colors.white.withValues(alpha: 0.15);
        fg = Colors.white70;
        break;
      case AdapterState.error:
        bg = const Color(0xFFE63946).withValues(alpha: 0.3);
        fg = Colors.white;
        break;
      default:
        bg = Colors.white.withValues(alpha: 0.1);
        fg = Colors.white60;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(status.message, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }
}

class _VitalChip extends StatelessWidget {
  const _VitalChip({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.unit,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8))),
          const SizedBox(width: 4),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(width: 2),
          Text(unit, style: TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7))),
        ],
      ),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F8F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD5E7DD).withValues(alpha: 0.6)),
      ),
      child: Text('$label  $value', style: const TextStyle(fontSize: 11)),
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
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F8F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFDCE3EA).withValues(alpha: 0.5)),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, height: 1.3)),
    );
  }
}

class _ChannelToggle extends StatelessWidget {
  const _ChannelToggle({required this.channel, required this.onChanged});

  final ChannelDescriptor channel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: colorFromHex(channel.colorHex),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${channel.label} (${channel.unit})', style: const TextStyle(fontSize: 12)),
          ),
          Switch(
            value: channel.enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ── Waveform card (monitor style) ─────────────────────────────────

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
    final viewport = _resolveStableViewport(_targetViewport());
    final channelColor = colorFromHex(widget.channel.colorHex);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B2A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: channelColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.channel.label,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: channelColor.withValues(alpha: 0.9)),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${widget.channel.unit})',
                  style: TextStyle(fontSize: 10, color: channelColor.withValues(alpha: 0.5)),
                ),
                const Spacer(),
                Text(
                  '${widget.channel.sampleRate.toStringAsFixed(0)} Hz',
                  style: TextStyle(fontSize: 10, color: Colors.teal[200]!.withValues(alpha: 0.5)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _healthColor(healthText).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    healthText,
                    style: TextStyle(fontSize: 10, color: _healthColor(healthText)),
                  ),
                ),
              ],
            ),
          ),
          if (widget.enableHoverInspect && _hoverInfo != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                '${_hoverInfo!.sample.value.toStringAsFixed(4)} ${widget.channel.unit} @ ${_formatTimestamp(_hoverInfo!.sample.timestampMs)}',
                style: TextStyle(fontSize: 10, color: Colors.teal[100]!.withValues(alpha: 0.7)),
              ),
            ),
          SizedBox(
            height: 200,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final width = constraints.maxWidth;
                const height = 200.0;
                return MouseRegion(
                  onExit: (_) {
                    if (_hoverInfo != null) setState(() => _hoverInfo = null);
                  },
                  onHover: (event) {
                    if (!widget.enableHoverInspect) return;
                    final nowMs = DateTime.now().millisecondsSinceEpoch;
                    if (nowMs - _lastHoverUpdateMs < 120) return;
                    _lastHoverUpdateMs = nowMs;
                    final nextHover = _resolveHover(
                      localPosition: event.localPosition,
                      width: width,
                      height: height,
                    );
                    if (_hoverEquals(_hoverInfo, nextHover)) return;
                    setState(() => _hoverInfo = nextHover);
                  },
                  child: Stack(
                    children: <Widget>[
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _WaveformPainter(
                              points: widget.points,
                              viewport: viewport,
                              color: channelColor,
                              gain: widget.gain,
                              secondsPerScreen: widget.secondsPerScreen,
                              anchorTimestampMs: widget.anchorTimestampMs,
                              showLabels: widget.enableHoverInspect,
                            ),
                            child: widget.points.isEmpty
                                ? Center(
                                    child: Text(
                                      '当前窗口暂无数据',
                                      style: TextStyle(color: Colors.teal[200]!.withValues(alpha: 0.4), fontSize: 12),
                                    ),
                                  )
                                : const SizedBox.expand(),
                          ),
                        ),
                      ),
                      if (_hoverInfo != null) ...<Widget>[
                        Positioned(
                          left: _hoverInfo!.localDx - 0.5,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 1, color: Colors.teal[100]!.withValues(alpha: 0.4)),
                        ),
                        Positioned(
                          left: _hoverInfo!.localDx - 4,
                          top: _hoverInfo!.localDy - 4,
                          child: IgnorePointer(
                            child: Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: channelColor,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 1.5),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: _bubbleLeft(_hoverInfo!, width),
                          top: _bubbleTop(_hoverInfo!, height),
                          child: IgnorePointer(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A2F3A),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: channelColor.withValues(alpha: 0.3)),
                              ),
                              child: DefaultTextStyle(
                                style: TextStyle(color: Colors.teal[100], fontSize: 10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(_formatTimestamp(_hoverInfo!.sample.timestampMs)),
                                    const SizedBox(height: 2),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: <Widget>[
                Text(
                  '样本 ${widget.summary['samples'] ?? 0} | 帧 ${runtime.receivedFrames}',
                  style: TextStyle(fontSize: 10, color: Colors.teal[200]!.withValues(alpha: 0.4)),
                ),
                const Spacer(),
                if (estimatedRate != null)
                  Text(
                    '${estimatedRate.toStringAsFixed(1)} BPM',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: channelColor),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _healthColor(String text) {
    if (text.contains('滞后') || text.contains('断档')) return const Color(0xFFF4A261);
    if (text == '实时') return const Color(0xFF2A9D8F);
    return const Color(0xFF8D99AE);
  }

  HoverSampleInfo? _resolveHover({required Offset localPosition, required double width, required double height}) {
    if (widget.points.isEmpty || width <= 0 || height <= 0) return null;
    final windowMs = (widget.secondsPerScreen * 1000).round();
    final startMs = widget.anchorTimestampMs - windowMs;
    final chartWidth = math.max(1.0, width - _waveformYAxisWidth);
    final clampedDx = (localPosition.dx - _waveformYAxisWidth).clamp(0.0, chartWidth);
    final targetMs = startMs + (clampedDx / chartWidth * windowMs).round();
    final sample = _nearestSample(widget.points, targetMs);
    final viewport = _stableViewport ?? _targetViewport();
    final sampleDx = _waveformYAxisWidth +
        ((sample.timestampMs - startMs) / windowMs).clamp(0.0, 1.0) * chartWidth;
    final sampleDy = viewport.dyForValue(value: sample.value, gain: widget.gain, height: height);
    return HoverSampleInfo(sample: sample, localDx: sampleDx, localDy: sampleDy);
  }

  _WaveformViewport _targetViewport() {
    return _WaveformViewport.fromBounds(minValue: widget.minValue, maxValue: widget.maxValue);
  }

  _WaveformViewport _resolveStableViewport(_WaveformViewport target) {
    final previous = _stableViewport;
    if (previous == null || widget.points.isEmpty) {
      _stableViewport = target;
      return target;
    }
    final nextMin = target.minLabel < previous.minLabel
        ? target.minLabel
        : previous.minLabel + (target.minLabel - previous.minLabel) * 0.08;
    final nextMax = target.maxLabel > previous.maxLabel
        ? target.maxLabel
        : previous.maxLabel + (target.maxLabel - previous.maxLabel) * 0.08;
    _stableViewport = _WaveformViewport.fromLabelBounds(minLabel: nextMin, maxLabel: nextMax);
    return _stableViewport!;
  }

  SamplePoint _nearestSample(List<SamplePoint> points, int targetTimestampMs) {
    if (points.length == 1) return points.first;
    var low = 0;
    var high = points.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final current = points[mid].timestampMs;
      if (current == targetTimestampMs) return points[mid];
      if (current < targetTimestampMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (low >= points.length) return points.last;
    if (high < 0) return points.first;
    final lowPoint = points[low];
    final highPoint = points[high];
    return (lowPoint.timestampMs - targetTimestampMs).abs() < (highPoint.timestampMs - targetTimestampMs).abs() ? lowPoint : highPoint;
  }

  bool _hoverEquals(HoverSampleInfo? a, HoverSampleInfo? b) {
    if (a == null || b == null) return a == b;
    return a.sample.timestampMs == b.sample.timestampMs;
  }

  double _bubbleLeft(HoverSampleInfo info, double width) {
    return math.min(math.max(8, info.localDx + 12), math.max(8, width - 150));
  }

  double _bubbleTop(HoverSampleInfo info, double height) {
    final preferred = info.localDy < 72 ? info.localDy + 12 : info.localDy - 52;
    return math.min(math.max(8, preferred), math.max(8, height - 56));
  }

  String _formatTimestamp(int timestampMs) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';
  }

  double? _safeNullableDouble(dynamic value) => value is num ? value.toDouble() : null;
}

// ── Waveform painter (monitor dark style) ──────────────────────────

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
    final backgroundPaint = Paint()..color = const Color(0xFF0D1B2A);
    final gridPaint = Paint()
      ..color = const Color(0xFF1A3040)
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = const Color(0xFF2A4A5A)
      ..strokeWidth = 1;
    final midlinePaint = Paint()
      ..color = const Color(0xFF1E3A4A)
      ..strokeWidth = 1.2;
    final signalPaint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..isAntiAlias = false;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(12));
    canvas.drawRRect(rrect, backgroundPaint);
    canvas.save();
    canvas.clipRRect(rrect);

    const verticalDivisions = 8;
    const horizontalDivisions = 6;
    final chartLeft = _waveformYAxisWidth;
    final chartWidth = math.max(1.0, size.width - chartLeft);
    final chartRight = chartLeft + chartWidth;

    canvas.drawLine(Offset(chartLeft, 0), Offset(chartLeft, size.height), axisPaint);

    for (var i = 0; i <= verticalDivisions; i++) {
      final dx = chartLeft + chartWidth * i / verticalDivisions;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), gridPaint);
      if (showLabels) {
        final secondsLeft = secondsPerScreen - secondsPerScreen * i / verticalDivisions;
        final labelDx = i == verticalDivisions ? dx - 34 : dx + 4;
        _drawLabel(canvas, size, text: '-${secondsLeft.toStringAsFixed(1)}s', offset: Offset(labelDx, size.height - 16), color: const Color(0xFF4A6A7A));
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
      canvas.drawLine(Offset(chartLeft - 4, dy), Offset(chartLeft, dy), axisPaint);
      if (showLabels) {
        _drawLabel(
          canvas,
          size,
          text: labelValue.toStringAsFixed(2),
          offset: Offset(4, (dy - 7).clamp(2.0, size.height - 16)),
          color: const Color(0xFF4A6A7A),
        );
      }
    }

    final windowMs = (secondsPerScreen * 1000).round();
    final startMs = anchorTimestampMs - windowMs;
    final renderPoints = _downsamplePoints(points, maxPoints: math.max(96, size.width.round() * 2));
    final offsets = renderPoints
        .map((SamplePoint point) => Offset(
              (chartLeft +
                      ((point.timestampMs - startMs) / windowMs) * chartWidth)
                  .clamp(chartLeft, chartRight),
              viewport.dyForValue(
                  value: point.value, gain: gain, height: size.height),
            ))
        .toList(growable: false);

    final path = Path();
    final gapThresholdMs = math.max(250, math.min(1200, windowMs ~/ 10));
    var segmentStart = 0;
    for (var index = 1; index <= renderPoints.length; index++) {
      final isEnd = index == renderPoints.length;
      final hasGap = !isEnd &&
          renderPoints[index].timestampMs - renderPoints[index - 1].timestampMs > gapThresholdMs;
      if (isEnd || hasGap) {
        _appendPathSegment(path, offsets, segmentStart, index);
        segmentStart = index;
      }
    }
    canvas.drawPath(path, signalPaint);
    canvas.restore();
  }

  void _appendPathSegment(Path path, List<Offset> offsets, int start, int endExclusive) {
    if (endExclusive <= start) return;
    path.moveTo(offsets[start].dx, offsets[start].dy);
    for (var index = start + 1; index < endExclusive; index++) {
      path.lineTo(offsets[index].dx, offsets[index].dy);
    }
  }

  List<SamplePoint> _downsamplePoints(List<SamplePoint> source, {required int maxPoints}) {
    if (source.length <= maxPoints) return source;
    final chunkSize = math.max(1, (source.length / maxPoints).ceil());
    final reduced = <SamplePoint>[];
    for (var start = 0; start < source.length; start += chunkSize) {
      final end = math.min(source.length, start + chunkSize);
      var minPoint = source[start];
      var maxPoint = source[start];
      for (var index = start + 1; index < end; index++) {
        final point = source[index];
        if (point.value < minPoint.value) minPoint = point;
        if (point.value > maxPoint.value) maxPoint = point;
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

  void _drawLabel(Canvas canvas, Size size, {required String text, required Offset offset, Color color = const Color(0xFF51606B)}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: 9, color: color)),
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

  factory _WaveformViewport.fromBounds({required double minValue, required double maxValue}) {
    if (minValue == 0 && maxValue == 0) return const _WaveformViewport(center: 0, halfRange: 1);
    final center = (minValue + maxValue) / 2;
    var halfRange = (maxValue - minValue) / 2;
    if (halfRange.abs() < 0.0001) halfRange = 1;
    return _WaveformViewport(center: center, halfRange: halfRange * 1.1);
  }

  factory _WaveformViewport.fromLabelBounds({required double minLabel, required double maxLabel}) {
    final center = (minLabel + maxLabel) / 2;
    var halfRange = (maxLabel - minLabel) / 2;
    if (halfRange.abs() < 0.0001) halfRange = 1;
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

// ── Report card (enhanced) ─────────────────────────────────────────

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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD0D8D3).withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.description_outlined, size: 18, color: Color(0xFF457B9D)),
                const SizedBox(width: 6),
                Expanded(child: Text('云端分析报告', style: Theme.of(context).textTheme.titleMedium)),
                if (report.riskLevel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _riskColor(report.riskLevel).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _riskColor(report.riskLevel).withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      _riskLabel(report.riskLevel),
                      style: TextStyle(
                        color: _riskColor(report.riskLevel),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                if (report.confidence != null)
                  _MetricChip(label: '置信度', value: '${(report.confidence! * 100).toStringAsFixed(0)}%'),
                const SizedBox(width: 6),
                _MetricChip(label: '会话', value: report.sessionId.length > 8 ? '${report.sessionId.substring(0, 8)}...' : report.sessionId),
              ],
            ),
            if (isRuleFallback) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF8E0),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.info_outline, size: 14, color: Colors.amber[700]),
                    const SizedBox(width: 4),
                    Text('规则分析模式（未启用大模型）', style: TextStyle(fontSize: 11, color: Colors.amber[800])),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text('综合结论', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(report.summary, style: const TextStyle(fontSize: 12, height: 1.4)),
            if (report.findings.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('主要发现', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              for (final ReportFinding finding in report.findings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F8F6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 4, right: 6),
                          decoration: BoxDecoration(
                            color: _severityColor(finding.severity),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(finding.title, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 12)),
                              const SizedBox(height: 2),
                              Text(finding.detail, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7C72))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (report.recommendations.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('建议', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final String item in report.recommendations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('· $item', style: const TextStyle(fontSize: 12, height: 1.3)),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              '辅助预警，不构成医疗诊断',
              style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }
}
