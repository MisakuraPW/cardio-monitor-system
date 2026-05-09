import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'cloud_api_service.dart';
import 'data_sources.dart';
import 'models.dart';

class MonitorController extends ChangeNotifier {
  MonitorController()
      : mqttConfig = MqttAdapterConfig(),
        bluetoothConfig = BluetoothAdapterConfig(),
        cloudApi = CloudApiService(baseUrl: 'http://127.0.0.1:8000') {
    _mqttAdapter = MqttDataSourceAdapter(mqttConfig);
    _fileAdapter = FileReplayAdapter();
    _bluetoothAdapter = BluetoothDataSourceAdapter(bluetoothConfig);
    _bindAdapter(_mqttAdapter);
    _uiTickTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_hasPendingFrameNotify) {
        return;
      }
      _hasPendingFrameNotify = false;
      notifyListeners();
    });
  }

  final Uuid _uuid = const Uuid();

  final MqttAdapterConfig mqttConfig;
  final BluetoothAdapterConfig bluetoothConfig;
  final CloudApiService cloudApi;

  late final MqttDataSourceAdapter _mqttAdapter;
  late final FileReplayAdapter _fileAdapter;
  late final BluetoothDataSourceAdapter _bluetoothAdapter;

  DataSourceMode mode = DataSourceMode.wifi;
  DataSourceAdapter? _currentAdapter;
  StreamSubscription<SignalFrame>? _frameSubscription;
  StreamSubscription<AdapterStatus>? _statusSubscription;
  StreamSubscription<List<ChannelDescriptor>>? _catalogSubscription;
  StreamSubscription<TransportStats>? _statsSubscription;
  Timer? _notifyTimer;
  Timer? _uiTickTimer;
  bool _hasPendingFrameNotify = false;

  final List<String> _events = <String>[];
  final Map<String, WaveformBuffer> _buffers = <String, WaveformBuffer>{};
  final Map<String, ChannelRuntimeStats> _runtimeStats =
      <String, ChannelRuntimeStats>{};
  final Map<String, TransportStats> _transportStats =
      <String, TransportStats>{};
  Map<String, WaveformBufferSnapshot> _pausedSnapshots =
      <String, WaveformBufferSnapshot>{};
  List<ChannelDescriptor> _channelCatalog = <ChannelDescriptor>[];
  String _lastCatalogSignature = '';

  AdapterStatus status = AdapterStatus(
    state: AdapterState.idle,
    message: '等待连接',
    updatedAt: DateTime.now(),
  );

  SessionRecord? session;
  UploadTask? uploadTask;
  AnalysisJob? analysisJob;
  MedicalReport? report;

  int latestTimestampMs = 0;
  int? _pauseReferenceTimestampMs;
  bool isPaused = false;
  double secondsPerScreen = 8;
  double historyOffsetSeconds = 0;
  double gain = 1;
  double liveDisplayLagSeconds = 5;

  String cloudBaseUrl = 'http://127.0.0.1:8000';

  List<String> get events => List<String>.unmodifiable(_events);
  List<ChannelDescriptor> get channelCatalog =>
      List<ChannelDescriptor>.unmodifiable(_channelCatalog);
  List<ChannelDescriptor> get visibleChannels =>
      _channelCatalog.where((ChannelDescriptor item) => item.enabled).toList();
  String get replayFileName => _fileAdapter.replayFileName;
  bool get hasReplayFile => _fileAdapter.isLoaded;
  bool get isConnected =>
      status.state == AdapterState.connected || status.state == AdapterState.streaming;
  bool get canRollbackHistory => isPaused && maxHistoryOffsetSeconds > 0.05;

  int get currentAnchorTimestampMs {
    final liveBase = _liveAnchorTimestampMs();
    if (!isPaused) {
      return liveBase;
    }
    final pauseBase = _pauseReferenceTimestampMs ?? liveBase;
    return pauseBase - (historyOffsetSeconds * 1000).round();
  }

  LocalAnalysisSnapshot get localAnalysis => _buildLocalAnalysis();

  Future<void> setMode(DataSourceMode nextMode) async {
    if (mode == nextMode) {
      return;
    }
    await disconnect();
    mode = nextMode;
    if (nextMode == DataSourceMode.wifi) {
      _bindAdapter(_mqttAdapter);
    } else if (nextMode == DataSourceMode.file) {
      _bindAdapter(_fileAdapter);
    } else {
      _bindAdapter(_bluetoothAdapter);
    }
    _pushEvent('切换为 ${nextMode.label} 模式');
    _scheduleNotify();
  }

  void updateMqttConfig({
    String? host,
    int? port,
    String? path,
    bool? useTls,
    String? deviceId,
    String? username,
    String? password,
  }) {
    if (host != null) {
      mqttConfig.host = host;
    }
    if (port != null) {
      mqttConfig.port = port;
    }
    if (path != null) {
      mqttConfig.path = path;
    }
    if (useTls != null) {
      mqttConfig.useTls = useTls;
    }
    if (deviceId != null) {
      mqttConfig.deviceId = deviceId;
    }
    if (username != null) {
      mqttConfig.username = username;
    }
    if (password != null) {
      mqttConfig.password = password;
    }
    _scheduleNotify();
  }

  void updateBluetoothConfig({
    String? deviceNamePrefix,
    String? serviceUuid,
    String? notifyCharacteristicUuid,
    String? controlCharacteristicUuid,
  }) {
    if (deviceNamePrefix != null) {
      bluetoothConfig.deviceNamePrefix = deviceNamePrefix;
    }
    if (serviceUuid != null) {
      bluetoothConfig.serviceUuid = serviceUuid;
    }
    if (notifyCharacteristicUuid != null) {
      bluetoothConfig.notifyCharacteristicUuid = notifyCharacteristicUuid;
    }
    if (controlCharacteristicUuid != null) {
      bluetoothConfig.controlCharacteristicUuid = controlCharacteristicUuid;
    }
    _scheduleNotify();
  }

  void updateCloudBaseUrl(String value) {
    cloudBaseUrl = value.trim();
    cloudApi.baseUrl = cloudBaseUrl;
    _scheduleNotify();
  }

  Future<void> pickReplayFile() async {
    await _fileAdapter.pickFile();
    if (_fileAdapter.parsedChannels.isNotEmpty) {
      _pushEvent('已选择回放文件 ${_fileAdapter.replayFileName}');
      _scheduleNotify();
    }
  }

  Future<void> connect() async {
    final adapter = _currentAdapter;
    if (adapter == null) {
      return;
    }

    if (mode == DataSourceMode.file && !_fileAdapter.isLoaded) {
      await pickReplayFile();
      if (!_fileAdapter.isLoaded) {
        return;
      }
    }

    if (_channelCatalog.isNotEmpty) {
      await adapter.updateChannels(_channelCatalog);
    }

    _buffers.clear();
    _runtimeStats.clear();
    _pausedSnapshots = <String, WaveformBufferSnapshot>{};
    _lastCatalogSignature = '';
    report = null;
    uploadTask = null;
    analysisJob = null;
    latestTimestampMs = 0;
    isPaused = false;
    historyOffsetSeconds = 0;
    _pauseReferenceTimestampMs = null;
    session = SessionRecord(
      id: _uuid.v4(),
      deviceId: mode == DataSourceMode.wifi
          ? mqttConfig.deviceId
          : mode == DataSourceMode.bluetooth
              ? bluetoothConfig.deviceNamePrefix
              : 'local-replay',
      sourceMode: mode.name,
      startedAt: DateTime.now().toUtc().toIso8601String(),
      channelKeys: _channelCatalog.map((ChannelDescriptor item) => item.key).toList(),
    );

    _pushEvent('开始新的监测会话 ${session!.id}');
    _scheduleNotify();
    await adapter.connect();
  }

  Future<void> disconnect() async {
    isPaused = false;
    historyOffsetSeconds = 0;
    _pauseReferenceTimestampMs = null;
    _pausedSnapshots = <String, WaveformBufferSnapshot>{};
    await _currentAdapter?.disconnect();
    _scheduleNotify();
  }

  Future<void> toggleChannel(String key, bool enabled) async {
    final updated = _channelCatalog
        .map(
          (ChannelDescriptor item) =>
              item.key == key ? item.copyWith(enabled: enabled) : item,
        )
        .toList();
    _setCatalog(updated);
    await _currentAdapter?.updateChannels(updated);
    _pushEvent('${enabled ? '启用' : '禁用'}通道 $key');
    _scheduleNotify();
  }

  void setSecondsPerScreen(double value) {
    secondsPerScreen = value;
    if (isPaused) {
      historyOffsetSeconds = historyOffsetSeconds.clamp(0.0, maxHistoryOffsetSeconds);
    } else {
      historyOffsetSeconds = 0;
    }
    _scheduleNotify();
  }

  void setHistoryOffsetSeconds(double value) {
    if (!isPaused) {
      historyOffsetSeconds = 0;
      _scheduleNotify();
      return;
    }
    historyOffsetSeconds = value.clamp(0.0, maxHistoryOffsetSeconds);
    _scheduleNotify();
  }

  void setGain(double value) {
    gain = value;
    _scheduleNotify();
  }

  void setLiveDisplayLagSeconds(double value) {
    liveDisplayLagSeconds = value;
    if (isPaused) {
      historyOffsetSeconds = historyOffsetSeconds.clamp(
        0.0,
        maxHistoryOffsetSeconds,
      );
    }
    _scheduleNotify();
  }

  void togglePause() {
    if (isPaused) {
      isPaused = false;
      historyOffsetSeconds = 0;
      _pauseReferenceTimestampMs = null;
      _pausedSnapshots = <String, WaveformBufferSnapshot>{};
      _pushEvent('恢复实时播放，并跳转到最新位置');
    } else {
      final pauseAnchor = currentAnchorTimestampMs;
      _pausedSnapshots = _buildPauseSnapshots();
      isPaused = true;
      historyOffsetSeconds = 0;
      _pauseReferenceTimestampMs = pauseAnchor;
      _pushEvent('已暂停实时播放，历史快照已冻结，可自由回滚查看');
    }
    _scheduleNotify();
  }

  double get maxHistoryOffsetSeconds {
    final reference = isPaused
        ? (_pauseReferenceTimestampMs ?? _liveAnchorTimestampMs())
        : _liveAnchorTimestampMs();
    final stores = _activeWaveformStores().toList();
    if (stores.isEmpty || reference == 0) {
      return 0;
    }
    final candidates = stores
        .where((WaveformHistoryStore item) => item.hasPoints)
        .map((WaveformHistoryStore item) => item.oldestTimestampMs)
        .toList();
    if (candidates.isEmpty) {
      return 0;
    }
    final oldest = candidates.reduce(math.min);
    final span = reference - oldest;
    return math.max(0, span / 1000 - secondsPerScreen).toDouble();
  }

  WaveformSlice visibleWaveform(String channelKey) {
    final store = _waveformStoreFor(channelKey);
    if (store == null) {
      return WaveformSlice.empty;
    }
    return store.visibleWaveform(
      anchorMs: currentAnchorTimestampMs,
      windowMs: (secondsPerScreen * 1000).round(),
    );
  }

  List<SamplePoint> visiblePoints(String channelKey) {
    return visibleWaveform(channelKey).points;
  }

  Map<String, dynamic> channelSummary(String channelKey) {
    return _waveformStoreFor(channelKey)?.summary() ?? const <String, dynamic>{};
  }

  ChannelRuntimeStats channelRuntime(String channelKey) {
    return _runtimeStats[channelKey] ?? ChannelRuntimeStats.empty(channelKey);
  }

  List<TransportStats> get transportStats =>
      _transportStats.values.toList(growable: false)
        ..sort((TransportStats a, TransportStats b) => a.source.compareTo(b.source));

  Future<void> uploadAndAnalyze() async {
    final localSession = session;
    if (localSession == null || _buffers.isEmpty) {
      _pushEvent('当前没有可上传的数据');
      _scheduleNotify();
      return;
    }

    try {
      cloudApi.baseUrl = cloudBaseUrl;
      _pushEvent('开始上传监测摘要到云端');

      final cloudSession = await cloudApi.createSession(localSession);
      session = cloudSession;

      final summary = _buildSummaryPayload();
      final excerpts = _buildExcerptPayload();
      uploadTask = await cloudApi.uploadSessionData(
        sessionId: cloudSession.id,
        summary: summary,
        excerpts: excerpts,
      );
      _pushEvent('摘要上传完成，任务 ${uploadTask!.id}');

      analysisJob = await cloudApi.createAnalysisJob(cloudSession.id);
      _pushEvent('分析任务已创建 ${analysisJob!.id}');

      for (var attempt = 0; attempt < 6; attempt++) {
        analysisJob = await cloudApi.getAnalysisJob(analysisJob!.id);
        if (analysisJob!.status == 'completed') {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }

      report = await cloudApi.getReport(cloudSession.id);
      _pushEvent('云端报告已回传');
    } catch (error) {
      _pushEvent('上传或分析失败: $error');
      status = AdapterStatus(
        state: AdapterState.error,
        message: '上传或分析失败: $error',
        updatedAt: DateTime.now(),
      );
    }

    _scheduleNotify();
  }

  void _bindAdapter(DataSourceAdapter adapter) {
    _frameSubscription?.cancel();
    _statusSubscription?.cancel();
    _catalogSubscription?.cancel();
    _statsSubscription?.cancel();
    _currentAdapter = adapter;
    _frameSubscription = adapter.streamFrames.listen(_onFrame);
    _statusSubscription = adapter.streamStatus.listen(_onStatus);
    _catalogSubscription = adapter.streamCatalog.listen(_onCatalog);
    _statsSubscription = adapter.streamTransportStats.listen(_onTransportStats);
  }

  void _onCatalog(List<ChannelDescriptor> channels) {
    final nextSignature = _catalogSignature(channels);
    if (nextSignature == _lastCatalogSignature) {
      return;
    }
    _setCatalog(channels);
    _pushEvent('目录同步完成，共 ${channels.length} 个通道');
    _scheduleNotify();
  }

  void _onFrame(SignalFrame frame) {
    final frameLatestTimestampMs = _latestFrameTimestampMs(frame);
    latestTimestampMs = latestTimestampMs == 0
        ? frameLatestTimestampMs
        : math.max(latestTimestampMs, frameLatestTimestampMs);
    if (_channelCatalog.every((ChannelDescriptor item) => item.key != frame.channelKey)) {
      _mergeFrameChannel(frame);
    }
    final buffer = _buffers.putIfAbsent(
      frame.channelKey,
      () => WaveformBuffer(channelKey: frame.channelKey),
    );
    buffer.appendFrame(frame);
    _runtimeStats
        .putIfAbsent(
          frame.channelKey,
          () => ChannelRuntimeStats.empty(frame.channelKey),
        )
        .observeFrame(
          frame: frame,
          latestSampleTimestampMs: frameLatestTimestampMs,
          receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
    _markFrameDirty();
  }

  void _onTransportStats(TransportStats stats) {
    _transportStats[stats.source] = stats;
    _scheduleNotify();
  }

  Map<String, WaveformBufferSnapshot> _buildPauseSnapshots() {
    return _buffers.map(
      (String key, WaveformBuffer buffer) =>
          MapEntry<String, WaveformBufferSnapshot>(key, buffer.snapshot()),
    );
  }

  WaveformHistoryStore? _waveformStoreFor(String channelKey) {
    if (isPaused && _pausedSnapshots.isNotEmpty) {
      return _pausedSnapshots[channelKey];
    }
    return _buffers[channelKey];
  }

  Iterable<WaveformHistoryStore> _activeWaveformStores() {
    if (isPaused && _pausedSnapshots.isNotEmpty) {
      return _pausedSnapshots.values;
    }
    return _buffers.values;
  }

  void _onStatus(AdapterStatus nextStatus) {
    status = nextStatus;
    _pushEvent(nextStatus.message);
    _scheduleNotify();
  }

  void _setCatalog(List<ChannelDescriptor> channels) {
    _channelCatalog = List<ChannelDescriptor>.from(channels);
    _lastCatalogSignature = _catalogSignature(_channelCatalog);
    for (final ChannelDescriptor item in _channelCatalog) {
      _buffers.putIfAbsent(item.key, () => WaveformBuffer(channelKey: item.key));
    }
    if (session != null) {
      session = SessionRecord(
        id: session!.id,
        deviceId: session!.deviceId,
        sourceMode: session!.sourceMode,
        startedAt: session!.startedAt,
        channelKeys: _channelCatalog.map((ChannelDescriptor item) => item.key).toList(),
      );
    }
  }

  void _mergeFrameChannel(SignalFrame frame) {
    final inferred = ChannelDescriptor(
      key: frame.channelKey,
      label: frame.channelKey.toUpperCase(),
      unit: frame.unit,
      sampleRate: frame.sampleRate,
      colorHex: '#247BA0',
      enabled: true,
    );
    _setCatalog(<ChannelDescriptor>[..._channelCatalog, inferred]);
  }

  String _catalogSignature(List<ChannelDescriptor> channels) {
    final stable = List<ChannelDescriptor>.from(channels)
      ..sort((ChannelDescriptor a, ChannelDescriptor b) => a.key.compareTo(b.key));
    return stable
        .map(
          (ChannelDescriptor item) => <String>[
            item.key,
            item.label,
            item.unit,
            item.colorHex,
            item.enabled ? '1' : '0',
          ].join('|'),
        )
        .join(';');
  }

  int _latestFrameTimestampMs(SignalFrame frame) {
    final sampleTimestamps = frame.sampleTimestampsMs;
    if (sampleTimestamps != null && sampleTimestamps.isNotEmpty) {
      return sampleTimestamps.last;
    }
    if (frame.samples.isEmpty) {
      return frame.timestampMs;
    }
    final stepMs = frame.sampleRate <= 0 ? 1 : (1000 / frame.sampleRate).round();
    return frame.timestampMs + stepMs * (frame.samples.length - 1);
  }

  Map<String, dynamic> _buildSummaryPayload() {
    final snapshot = localAnalysis;
    final channelSummaries = <String, dynamic>{};
    for (final ChannelDescriptor descriptor in _channelCatalog) {
      final summary = _buffers[descriptor.key]?.summary();
      if (summary == null || summary.isEmpty) {
        continue;
      }
      channelSummaries[descriptor.key] = summary;
    }

    return <String, dynamic>{
      'durationSeconds': snapshot.durationSeconds,
      'qualityScore': snapshot.meanQuality,
      'channels': channelSummaries,
      'mode': mode.name,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'localAnalysis': <String, dynamic>{
        'activeChannels': snapshot.activeChannels,
        'durationSeconds': snapshot.durationSeconds,
        'meanQuality': snapshot.meanQuality,
        'findings': snapshot.findings,
        'channels': snapshot.channels
            .map(
              (LocalChannelAnalysis item) => <String, dynamic>{
                'channelKey': item.channelKey,
                'label': item.label,
                'unit': item.unit,
                'sampleCount': item.sampleCount,
                'durationSeconds': item.durationSeconds,
                'mean': item.mean,
                'min': item.min,
                'max': item.max,
                'rms': item.rms,
                'stdDev': item.stdDev,
                'peakToPeak': item.peakToPeak,
                'meanQuality': item.meanQuality,
                'estimatedRateBpm': item.estimatedRateBpm,
                'notes': item.notes,
              },
            )
            .toList(),
      },
    };
  }

  Map<String, dynamic> _buildExcerptPayload() {
    final excerpts = <String, dynamic>{};
    for (final ChannelDescriptor descriptor
        in _channelCatalog.where((ChannelDescriptor item) => item.enabled)) {
      final buffer = _buffers[descriptor.key];
      if (buffer == null || !buffer.hasPoints) {
        continue;
      }
      excerpts[descriptor.key] = buffer.tailValues(maxItems: 24);
    }
    return excerpts;
  }

  LocalAnalysisSnapshot _buildLocalAnalysis() {
    final channels = <LocalChannelAnalysis>[];
    final findings = <String>[];
    var qualityAccumulator = 0.0;
    var qualityCount = 0;
    var longestDuration = 0.0;

    for (final ChannelDescriptor descriptor
        in _channelCatalog.where((ChannelDescriptor item) => item.enabled)) {
      final summary = _buffers[descriptor.key]?.summary();
      if (summary == null || summary.isEmpty) {
        continue;
      }

      final durationSeconds = _asDouble(summary['durationSeconds']);
      final meanQuality = _asDouble(summary['meanQuality']);
      final estimatedRate = _asNullableDouble(summary['estimatedRateBpm']);
      final notes = <String>[];

      if (durationSeconds < math.max(4, secondsPerScreen / 2)) {
        notes.add('数据时长偏短');
      }
      if (meanQuality < 0.75) {
        notes.add('平均质量偏低');
      }
      if (estimatedRate != null) {
        notes.add('估计节律 ${estimatedRate.toStringAsFixed(1)} BPM');
      }
      if (descriptor.key.contains('spo2')) {
        notes.add('可用于血氧趋势预览');
      }
      if (descriptor.key.contains('temp')) {
        notes.add('可用于体温趋势预览');
      }

      channels.add(
        LocalChannelAnalysis(
          channelKey: descriptor.key,
          label: descriptor.label,
          unit: descriptor.unit,
          sampleCount: (summary['samples'] as num? ?? 0).toInt(),
          durationSeconds: durationSeconds,
          mean: _asDouble(summary['mean']),
          min: _asDouble(summary['min']),
          max: _asDouble(summary['max']),
          rms: _asDouble(summary['rms']),
          stdDev: _asDouble(summary['stdDev']),
          peakToPeak: _asDouble(summary['peakToPeak']),
          meanQuality: meanQuality,
          estimatedRateBpm: estimatedRate,
          notes: notes,
        ),
      );

      qualityAccumulator += meanQuality;
      qualityCount += 1;
      longestDuration = math.max(longestDuration, durationSeconds);

      if (durationSeconds < 6) {
        findings.add('${descriptor.label} 当前缓存时长较短，更适合调试而非判读。');
      }
      if (estimatedRate != null) {
        findings.add('${descriptor.label} 检测到约 ${estimatedRate.toStringAsFixed(1)} BPM 的周期性变化。');
      }
      if (descriptor.key.contains('spo2')) {
        findings.add('${descriptor.label} 平均值约 ${_asDouble(summary['mean']).toStringAsFixed(1)} ${descriptor.unit}。');
      }
      if (descriptor.key.contains('temp')) {
        findings.add('${descriptor.label} 平均值约 ${_asDouble(summary['mean']).toStringAsFixed(2)} ${descriptor.unit}。');
      }
    }

    if (channels.isEmpty) {
      findings.add('尚未形成可用的本地统计结果，请先导入文件或连接设备。');
    } else {
      findings.insert(0, '本地区域已预留简单模型接口，可继续扩展去噪、峰值检测和节律分类。');
    }

    return LocalAnalysisSnapshot(
      activeChannels: channels.length,
      durationSeconds: longestDuration,
      meanQuality: qualityCount == 0 ? 0 : qualityAccumulator / qualityCount,
      channels: channels,
      findings: _deduplicateFindings(findings).take(8).toList(),
    );
  }

  List<String> _deduplicateFindings(List<String> findings) {
    final seen = <String>{};
    final ordered = <String>[];
    for (final String item in findings) {
      if (seen.add(item)) {
        ordered.add(item);
      }
    }
    return ordered;
  }

  double _asDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }

  double? _asNullableDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  void _pushEvent(String message) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    _events.insert(0, '[$stamp] $message');
    if (_events.length > 60) {
      _events.removeLast();
    }
  }

  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) {
      return;
    }
    _notifyTimer = Timer(const Duration(milliseconds: 24), notifyListeners);
  }

  void _markFrameDirty() {
    _hasPendingFrameNotify = true;
  }

  int _liveAnchorTimestampMs() {
    final liveBase = latestTimestampMs == 0
        ? DateTime.now().millisecondsSinceEpoch
        : latestTimestampMs;
    return liveBase - (liveDisplayLagSeconds * 1000).round();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _uiTickTimer?.cancel();
    _frameSubscription?.cancel();
    _statusSubscription?.cancel();
    _catalogSubscription?.cancel();
    _statsSubscription?.cancel();
    _mqttAdapter.dispose();
    _fileAdapter.dispose();
    _bluetoothAdapter.dispose();
    cloudApi.dispose();
    super.dispose();
  }
}

class ChannelRuntimeStats {
  ChannelRuntimeStats.empty(this.channelKey);

  final String channelKey;
  int? lastSeq;
  int receivedFrames = 0;
  int receivedSamples = 0;
  int missingFrames = 0;
  int outOfOrderFrames = 0;
  int sampleGapEvents = 0;
  int largestSampleGapMs = 0;
  int crcErrorFrames = 0;
  int decodeErrorFrames = 0;
  int lastReceivedAtMs = 0;
  int latestSampleTimestampMs = 0;
  int lastSampleCount = 0;
  int latestFrameVersion = 1;
  String lastTransport = 'unknown';

  bool get hasData => receivedFrames > 0;

  void observeFrame({
    required SignalFrame frame,
    required int latestSampleTimestampMs,
    required int receivedAtMs,
  }) {
    receivedFrames += 1;
    receivedSamples += frame.samples.length;
    lastSampleCount = frame.samples.length;
    lastReceivedAtMs = receivedAtMs;
    latestFrameVersion = frame.frameVersion;
    lastTransport = frame.transport;
    if (frame.decodeStatus == 'crc_error') {
      crcErrorFrames += 1;
    } else if (frame.decodeStatus != 'ok') {
      decodeErrorFrames += 1;
    }
    _observeSeq(frame.seq);
    _observeTimestampGaps(frame);
    this.latestSampleTimestampMs = math.max(
      this.latestSampleTimestampMs,
      latestSampleTimestampMs,
    );
  }

  double idleSeconds({int? nowMs}) {
    if (lastReceivedAtMs <= 0) {
      return 0;
    }
    final reference = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return math.max(0, reference - lastReceivedAtMs) / 1000.0;
  }

  double lagBehindAnchorSeconds(int anchorTimestampMs) {
    if (latestSampleTimestampMs <= 0 || anchorTimestampMs <= 0) {
      return 0;
    }
    return math.max(0, anchorTimestampMs - latestSampleTimestampMs) / 1000.0;
  }

  String healthText(int anchorTimestampMs) {
    if (!hasData) {
      return '等待数据';
    }
    final lagSeconds = lagBehindAnchorSeconds(anchorTimestampMs);
    if (lagSeconds >= 1.0) {
      return '滞后 ${lagSeconds.toStringAsFixed(1)} s';
    }
    if (missingFrames > 0 || sampleGapEvents > 0) {
      return '有断档';
    }
    return '实时';
  }

  void _observeSeq(int seq) {
    final previousSeq = lastSeq;
    final shouldTrackSeq = seq > 0 || (previousSeq ?? 0) > 0;
    if (!shouldTrackSeq) {
      lastSeq = seq;
      return;
    }
    if (previousSeq != null) {
      if (seq > previousSeq + 1) {
        missingFrames += seq - previousSeq - 1;
      } else if (seq <= previousSeq) {
        outOfOrderFrames += 1;
      }
    }
    if (previousSeq == null || seq > previousSeq) {
      lastSeq = seq;
    }
  }

  void _observeTimestampGaps(SignalFrame frame) {
    final timestamps = frame.sampleTimestampsMs;
    if (timestamps == null || timestamps.isEmpty) {
      return;
    }
    final expectedStepMs = frame.sampleRate <= 0 ? 0 : 1000 / frame.sampleRate;
    final gapThresholdMs = math.max(50, (expectedStepMs * 3).round());
    var previous = latestSampleTimestampMs > 0 ? latestSampleTimestampMs : timestamps.first;
    for (final int timestamp in timestamps) {
      final gap = timestamp - previous;
      if (gap > gapThresholdMs) {
        sampleGapEvents += 1;
        largestSampleGapMs = math.max(largestSampleGapMs, gap);
      }
      previous = timestamp;
    }
  }
}

abstract class WaveformHistoryStore {
  bool get hasPoints;
  int get oldestTimestampMs;
  int get latestPointTimestampMs;

  WaveformSlice visibleWaveform({
    required int anchorMs,
    required int windowMs,
  });

  Map<String, dynamic> summary();
  List<double> tailValues({required int maxItems});
}

WaveformSlice _buildWaveformSlice(
  List<SamplePoint> points,
  int firstVisibleIndex,
  int endExclusive,
) {
  const maxVisiblePoints = 2400;
  var minValue = points[firstVisibleIndex].value;
  var maxValue = minValue;
  final length = endExclusive - firstVisibleIndex;
  for (var index = firstVisibleIndex + 1; index < endExclusive; index++) {
    final value = points[index].value;
    minValue = math.min(minValue, value);
    maxValue = math.max(maxValue, value);
  }

  if (length <= maxVisiblePoints) {
    return WaveformSlice(
      points: List<SamplePoint>.generate(
        length,
        (int offset) => points[firstVisibleIndex + offset],
        growable: false,
      ),
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  final chunkSize = math.max(1, (length / maxVisiblePoints).ceil());
  final visible = <SamplePoint>[];
  void appendUnique(SamplePoint point) {
    if (visible.isNotEmpty &&
        visible.last.timestampMs == point.timestampMs &&
        visible.last.value == point.value) {
      return;
    }
    visible.add(point);
  }

  for (var start = firstVisibleIndex; start < endExclusive; start += chunkSize) {
    final end = math.min(endExclusive, start + chunkSize);
    var minPoint = points[start];
    var maxPoint = points[start];
    for (var index = start + 1; index < end; index++) {
      final point = points[index];
      if (point.value < minPoint.value) {
        minPoint = point;
      }
      if (point.value > maxPoint.value) {
        maxPoint = point;
      }
    }
    appendUnique(points[start]);
    if (minPoint.timestampMs <= maxPoint.timestampMs) {
      appendUnique(minPoint);
      appendUnique(maxPoint);
    } else {
      appendUnique(maxPoint);
      appendUnique(minPoint);
    }
    appendUnique(points[end - 1]);
  }

  return WaveformSlice(
    points: visible,
    minValue: minValue,
    maxValue: maxValue,
  );
}

class WaveformBufferSnapshot implements WaveformHistoryStore {
  WaveformBufferSnapshot({
    required this.channelKey,
    required List<SamplePoint> points,
    required Map<String, dynamic> summary,
  })  : _points = List<SamplePoint>.unmodifiable(points),
        _summary = Map<String, dynamic>.unmodifiable(summary);

  final String channelKey;
  final List<SamplePoint> _points;
  final Map<String, dynamic> _summary;

  @override
  bool get hasPoints => _points.isNotEmpty;

  @override
  int get oldestTimestampMs => hasPoints ? _points.first.timestampMs : 0;

  @override
  int get latestPointTimestampMs => hasPoints ? _points.last.timestampMs : 0;

  @override
  WaveformSlice visibleWaveform({
    required int anchorMs,
    required int windowMs,
  }) {
    if (!hasPoints) {
      return WaveformSlice.empty;
    }
    final start = anchorMs - windowMs;
    final firstVisibleIndex = _lowerBound(start);
    final endExclusive = _upperBound(anchorMs);
    if (firstVisibleIndex >= endExclusive) {
      return WaveformSlice.empty;
    }

    return _buildWaveformSlice(_points, firstVisibleIndex, endExclusive);
  }

  @override
  Map<String, dynamic> summary() => _summary;

  @override
  List<double> tailValues({required int maxItems}) {
    final start = _points.length <= maxItems ? 0 : _points.length - maxItems;
    return _points
        .sublist(start)
        .map((SamplePoint item) => item.value)
        .toList(growable: false);
  }

  int _lowerBound(int timestampMs) {
    var low = 0;
    var high = _points.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_points[mid].timestampMs < timestampMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int _upperBound(int timestampMs) {
    var low = 0;
    var high = _points.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_points[mid].timestampMs <= timestampMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

class WaveformBuffer implements WaveformHistoryStore {
  WaveformBuffer({required this.channelKey});

  final String channelKey;
  final List<SamplePoint> _points = <SamplePoint>[];
  int _startIndex = 0;
  double _qualityWeighted = 0;
  int _qualitySamples = 0;
  double _sum = 0;
  double _sumSquares = 0;
  double _min = 0;
  double _max = 0;
  Map<String, dynamic>? _cachedSummary;
  bool _summaryDirty = true;
  double? _cachedRateBpm;
  int _lastRateEstimateTimestampMs = 0;

  @override
  bool get hasPoints => activeLength > 0;

  @override
  int get oldestTimestampMs => hasPoints ? _points[_startIndex].timestampMs : 0;

  @override
  int get latestPointTimestampMs => hasPoints ? _points.last.timestampMs : 0;
  int get activeLength => _points.length - _startIndex;

  WaveformBufferSnapshot snapshot() {
    final activePoints = hasPoints
        ? _points.sublist(_startIndex)
        : const <SamplePoint>[];
    return WaveformBufferSnapshot(
      channelKey: channelKey,
      points: activePoints,
      summary: summary(),
    );
  }

  void appendFrame(SignalFrame frame) {
    final stepMs = frame.sampleRate <= 0 ? 1 : (1000 / frame.sampleRate).round();
    final sampleTimestamps = frame.sampleTimestampsMs;
    for (var index = 0; index < frame.samples.length; index++) {
      final point = SamplePoint(
        timestampMs: sampleTimestamps != null && index < sampleTimestamps.length
            ? sampleTimestamps[index]
            : frame.timestampMs + stepMs * index,
        value: frame.samples[index],
      );
      _appendPoint(point);
      _qualityWeighted += frame.quality;
      _qualitySamples += 1;
    }
    _trim();
  }

  @override
  WaveformSlice visibleWaveform({
    required int anchorMs,
    required int windowMs,
  }) {
    if (!hasPoints) {
      return WaveformSlice.empty;
    }
    final start = anchorMs - windowMs;
    final firstVisibleIndex = _lowerBound(start);
    final endExclusive = _upperBound(anchorMs);
    if (firstVisibleIndex >= endExclusive) {
      return WaveformSlice.empty;
    }

    return _buildWaveformSlice(_points, firstVisibleIndex, endExclusive);
  }

  @override
  Map<String, dynamic> summary() {
    if (!hasPoints) {
      return const <String, dynamic>{};
    }
    if (!_summaryDirty && _cachedSummary != null) {
      return _cachedSummary!;
    }

    final sampleCount = activeLength;
    final mean = _sum / sampleCount;
    final rms = math.sqrt(_sumSquares / sampleCount);
    final variance = math.max(0, (_sumSquares / sampleCount) - mean * mean);
    final stdDev = math.sqrt(variance);
    final durationSeconds = sampleCount <= 1
        ? 0.0
        : (latestPointTimestampMs - oldestTimestampMs) / 1000.0;
    final latestTimestampMs = latestPointTimestampMs;
    if (_cachedRateBpm == null ||
        latestTimestampMs - _lastRateEstimateTimestampMs >= 500) {
      _cachedRateBpm = _estimateRateBpm(
        mean: mean,
        durationSeconds: durationSeconds,
      );
      _lastRateEstimateTimestampMs = latestTimestampMs;
    }

    final summary = <String, dynamic>{
      'samples': sampleCount,
      'min': _min,
      'max': _max,
      'mean': mean,
      'rms': rms,
      'stdDev': stdDev,
      'peakToPeak': _max - _min,
      'durationSeconds': durationSeconds,
      'meanQuality': _qualitySamples == 0 ? 0 : _qualityWeighted / _qualitySamples,
      'estimatedRateBpm': _cachedRateBpm,
    };
    _cachedSummary = summary;
    _summaryDirty = false;
    return summary;
  }

  @override
  List<double> tailValues({required int maxItems}) {
    final length = activeLength;
    final start = length <= maxItems ? _startIndex : _points.length - maxItems;
    final tail = _points.sublist(start);
    return tail.map((SamplePoint item) => item.value).toList();
  }

  void _appendPoint(SamplePoint point) {
    if (!hasPoints) {
      _min = point.value;
      _max = point.value;
      _points.add(point);
    } else {
      _min = math.min(_min, point.value);
      _max = math.max(_max, point.value);
      if (point.timestampMs >= _points.last.timestampMs) {
        _points.add(point);
      } else {
        final insertIndex = _upperBound(point.timestampMs);
        _points.insert(insertIndex, point);
      }
    }
    _sum += point.value;
    _sumSquares += point.value * point.value;
    _summaryDirty = true;
  }

  double? _estimateRateBpm({required double mean, required double durationSeconds}) {
    if (activeLength < 20 || durationSeconds < 3) {
      return null;
    }

    final dynamicRange = _max - _min;
    if (dynamicRange.abs() < 0.0001) {
      return null;
    }

    final threshold = mean + dynamicRange * 0.28;
    const minPeakDistanceMs = 280;
    final peakTimes = <int>[];
    double? lastPeakValue;

    for (var index = _startIndex + 1; index < _points.length - 1; index++) {
      final previous = _points[index - 1];
      final current = _points[index];
      final next = _points[index + 1];
      final isPeak = current.value > previous.value &&
          current.value >= next.value &&
          current.value >= threshold;
      if (!isPeak) {
        continue;
      }
      if (peakTimes.isNotEmpty &&
          current.timestampMs - peakTimes.last < minPeakDistanceMs) {
        if (lastPeakValue == null || current.value > lastPeakValue) {
          peakTimes[peakTimes.length - 1] = current.timestampMs;
          lastPeakValue = current.value;
        }
        continue;
      }
      peakTimes.add(current.timestampMs);
      lastPeakValue = current.value;
    }

    if (peakTimes.length < 2) {
      return null;
    }

    var totalInterval = 0;
    for (var index = 1; index < peakTimes.length; index++) {
      totalInterval += peakTimes[index] - peakTimes[index - 1];
    }
    final meanIntervalMs = totalInterval / (peakTimes.length - 1);
    if (meanIntervalMs <= 0) {
      return null;
    }

    final bpm = 60000 / meanIntervalMs;
    if (bpm < 25 || bpm > 240) {
      return null;
    }
    return bpm;
  }

  void _trim() {
    const maxRetainedPoints = 60000;
    const compactionThreshold = 12000;
    final overflow = activeLength - maxRetainedPoints;
    if (overflow <= 0) {
      if (_startIndex >= compactionThreshold) {
        _compact();
      }
      return;
    }

    var needsRangeRebuild = false;
    for (var index = _startIndex; index < _startIndex + overflow; index++) {
      final item = _points[index];
      _sum -= item.value;
      _sumSquares -= item.value * item.value;
      if (item.value == _min || item.value == _max) {
        needsRangeRebuild = true;
      }
    }

    _startIndex += overflow;
    _summaryDirty = true;

    if (!hasPoints) {
      _min = 0;
      _max = 0;
      _sum = 0;
      _sumSquares = 0;
      _cachedSummary = null;
      _cachedRateBpm = null;
      _lastRateEstimateTimestampMs = 0;
      _points.clear();
      _startIndex = 0;
      return;
    }

    if (needsRangeRebuild) {
      _recomputeRange();
    }
    if (_startIndex >= compactionThreshold) {
      _compact();
    }
  }

  int _lowerBound(int timestampMs) {
    var low = _startIndex;
    var high = _points.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_points[mid].timestampMs < timestampMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int _upperBound(int timestampMs) {
    var low = _startIndex;
    var high = _points.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (_points[mid].timestampMs <= timestampMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void _compact() {
    if (_startIndex == 0) {
      return;
    }
    _points.removeRange(0, _startIndex);
    _startIndex = 0;
  }

  void _recomputeRange() {
    if (!hasPoints) {
      _min = 0;
      _max = 0;
      return;
    }
    var nextMin = _points[_startIndex].value;
    var nextMax = nextMin;
    for (var index = _startIndex + 1; index < _points.length; index++) {
      final value = _points[index].value;
      nextMin = math.min(nextMin, value);
      nextMax = math.max(nextMax, value);
    }
    _min = nextMin;
    _max = nextMax;
  }
}

