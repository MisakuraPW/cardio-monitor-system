import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'cloud_api_service.dart';
import 'data_sources.dart';
import 'models.dart';

class MonitorController extends ChangeNotifier {
  static const double _initialBufferTargetSeconds = 15;

  MonitorController()
      : mqttConfig = MqttAdapterConfig(),
        bluetoothConfig = BluetoothAdapterConfig(),
        cloudApi = CloudApiService(baseUrl: 'http://182.254.220.56:8000') {
    _mqttAdapter = MqttDataSourceAdapter(mqttConfig);
    _fileAdapter = FileReplayAdapter();
    _bluetoothAdapter = BluetoothDataSourceAdapter(bluetoothConfig);
    _segmentUploader = AutoSegmentUploader(
      onUpload: _uploadSegmentPayload,
      onUploaded: _onSegmentUploaded,
      onFailed: _onSegmentUploadFailed,
      buildMetrics: _buildSegmentMetrics,
    );
    _bindAdapter(_mqttAdapter);
    _uiTickTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final shouldAdvancePlayback =
          isConnected && !isPaused && !isStartupBuffering && mode != DataSourceMode.file;
      if (!_hasPendingFrameNotify && !shouldAdvancePlayback) {
        return;
      }
      _hasPendingFrameNotify = false;
      waveformNotifier.notifyListeners();
    });
  }

  final Uuid _uuid = const Uuid();

  final MqttAdapterConfig mqttConfig;
  final BluetoothAdapterConfig bluetoothConfig;
  final CloudApiService cloudApi;
  final ChangeNotifier waveformNotifier = ChangeNotifier();

  late final MqttDataSourceAdapter _mqttAdapter;
  late final FileReplayAdapter _fileAdapter;
  late final BluetoothDataSourceAdapter _bluetoothAdapter;
  late final AutoSegmentUploader _segmentUploader;

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
  final Map<String, int> _lastDisplayTimestampMsByChannel = <String, int>{};
  final Map<String, int> _lastAcceptedSeqByChannel = <String, int>{};
  final Map<String, int> _lastStatusTelemetryAcceptedAtMs = <String, int>{};
  final Set<String> _initiallyFilledChannels = <String>{};
  final Map<String, double> _latestImuValues = <String, double>{};
  int _latestImuReceivedAtMs = 0;
  double? _latestTemperatureCelsius;
  bool? _latestEcgLeadOn;

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
  int _displayAnchorMs = 0;
  int _lastAnchorWallMs = 0;
  int _livePlaybackStartAnchorMs = 0;
  int? _pauseReferenceTimestampMs;
  bool isPaused = false;
  double secondsPerScreen = 6;
  double historyOffsetSeconds = 0;
  double gain = 1;
  double liveDisplayLagSeconds = 2;
  double startupBufferSeconds = 30;

  String cloudBaseUrl = 'http://182.254.220.56:8000';
  String userName = '演示用户';
  bool autoSegmentUploadEnabled = true;
  int uploadedSegmentCount = 0;
  int pendingSegmentUploadCount = 0;
  int failedSegmentUploadCount = 0;
  SegmentRecord? latestSegment;

  final MonitoringAgentStatus agentStatus = MonitoringAgentStatus();
  String? _agentLastAnalyzedSegmentId;
  Timer? _agentCheckTimer;
  bool _agentAutoAnalyzeEnabled = true;

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
  bool get isStartupBuffering =>
      isConnected &&
      !isPaused &&
      mode != DataSourceMode.file &&
      !_hasInitialVisibleBufferReady();
  double get startupBufferProgress => _initialBufferProgress();
  double get _requiredLiveBufferSeconds => _initialBufferTargetSeconds;
  double get _targetPlaybackLagSeconds =>
      math.max(liveDisplayLagSeconds, _initialBufferTargetSeconds - secondsPerScreen);
  int get _liveRetentionMs =>
      (math.max(120.0, _requiredLiveBufferSeconds + secondsPerScreen + 30.0) * 1000).round();
  bool get isEcgWorn => _latestEcgLeadOn ?? true;
  double? get displayTemperatureCelsius =>
      _latestTemperatureCelsius ?? localAnalysis.physio.temperatureCelsius;
  bool get hasTemperatureData =>
      _latestTemperatureCelsius != null || localAnalysis.physio.temperatureCelsius != null;
  ImuDisplaySnapshot get imuDisplay => ImuDisplaySnapshot.fromValues(
        values: _latestImuValues,
        receivedAtMs: _latestImuReceivedAtMs,
      );

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
    cloudBaseUrl = normalizeCloudApiBaseUrl(value);
    cloudApi.baseUrl = cloudBaseUrl;
    _scheduleNotify();
  }

  void updateUserName(String value) {
    userName = value.trim().isEmpty ? '演示用户' : value.trim();
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
    _lastDisplayTimestampMsByChannel.clear();
    _lastAcceptedSeqByChannel.clear();
    _lastStatusTelemetryAcceptedAtMs.clear();
    _initiallyFilledChannels.clear();
    _latestImuValues.clear();
    _latestImuReceivedAtMs = 0;
    _latestTemperatureCelsius = null;
    _latestEcgLeadOn = null;
    _pausedSnapshots = <String, WaveformBufferSnapshot>{};
    _lastCatalogSignature = '';
    report = null;
    uploadTask = null;
    analysisJob = null;
    latestTimestampMs = 0;
    _displayAnchorMs = 0;
    _lastAnchorWallMs = 0;
    _livePlaybackStartAnchorMs = 0;
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
      userName: userName,
      metadata: <String, dynamic>{
        'autoSegmentUpload': autoSegmentUploadEnabled,
        'segmentDurationSeconds': AutoSegmentUploader.segmentDurationSeconds,
      },
    );

    _pushEvent('开始新的监测会话 ${session!.id}');
    _scheduleNotify();
    _segmentUploader.reset();
    uploadedSegmentCount = 0;
    pendingSegmentUploadCount = 0;
    failedSegmentUploadCount = 0;
    latestSegment = null;
    if (autoSegmentUploadEnabled) {
      await _openCloudSessionForAutoUpload();
    }
    _startAgentCheck();
    await adapter.connect();
  }

  Future<void> disconnect() async {
    isPaused = false;
    historyOffsetSeconds = 0;
    _pauseReferenceTimestampMs = null;
    _pausedSnapshots = <String, WaveformBufferSnapshot>{};
    _stopAgentCheck();
    await _currentAdapter?.disconnect();
    await _segmentUploader.flush();
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
    if (!isPaused && mode != DataSourceMode.file && isStartupBuffering) {
      return WaveformSlice.empty;
    }
    if (!isPaused && _shouldHoldChannelForInitialFill(channelKey)) {
      return WaveformSlice.empty;
    }
    if (_isEcgChannel(channelKey) && !isEcgWorn) {
      return WaveformSlice.empty;
    }
    final store = _waveformStoreFor(channelKey);
    if (store == null) {
      return WaveformSlice.empty;
    }
    return store.visibleWaveform(
      anchorMs: _anchorTimestampForChannel(channelKey),
      windowMs: (secondsPerScreen * 1000).round(),
    );
  }

  int anchorTimestampForChannel(String channelKey) => _anchorTimestampForChannel(channelKey);

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
      _pushEvent('开始上传监测摘要到云端');

      final cloudSession = await _ensureCloudSession();

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

  Future<void> analyzeLatestSegment() async {
    final localSession = session;
    final segment = latestSegment;
    if (localSession == null || segment == null) {
      _pushEvent('暂无可分析的自动分段');
      _scheduleNotify();
      return;
    }
    try {
      _pushEvent('开始分析最近分段 #${segment.segmentIndex}');
      final cloudSession = await _ensureCloudSession();
      report = await cloudApi.analyzeSegment(
        sessionId: cloudSession.id,
        segmentId: segment.id,
      );
      _pushEvent('最近分段报告已回传');
    } catch (error) {
      _pushEvent('分段分析失败: $error');
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
    final normalizedFrame = _normalizeFrameForLiveDisplay(frame);
    if (normalizedFrame == null) {
      return;
    }
    frame = normalizedFrame;

    if (_isImuChannel(frame.channelKey)) {
      if (!_acceptStatusTelemetryFrame(frame)) {
        return;
      }
      _observeImuFrame(frame);
      _scheduleNotify();
      return;
    }
    if (frame.channelKey == 'temp') {
      if (!_acceptStatusTelemetryFrame(frame)) {
        return;
      }
      _observeTemperatureFrame(frame);
      _scheduleNotify();
      return;
    }
    if (_isEcgChannel(frame.channelKey)) {
      final leadOn = frame.transport.startsWith('ble_') || frame.quality > 0.15;
      _latestEcgLeadOn = leadOn;
      if (!leadOn) {
        _buffers.remove(frame.channelKey);
        _markFrameDirty();
        return;
      }
    }

    final knownIndex = _channelCatalog.indexWhere(
      (ChannelDescriptor item) => item.key == frame.channelKey,
    );
    if (knownIndex >= 0 && !_channelCatalog[knownIndex].enabled) {
      return;
    }
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
    if (buffer.activeLength >= _initialSampleThresholdForChannel(frame.channelKey)) {
      _initiallyFilledChannels.add(frame.channelKey);
    }
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
    _segmentUploader.observeFrame(frame);
    _markFrameDirty();
  }

  void _onTransportStats(TransportStats stats) {
    _transportStats[stats.source] = stats;
    _scheduleNotify();
  }

  void _prepareCloudApi() {
    final normalized = normalizeCloudApiBaseUrl(cloudBaseUrl);
    cloudBaseUrl = normalized;
    cloudApi.baseUrl = normalized;
  }

  Future<SessionRecord> _ensureCloudSession({bool forceCreate = false}) async {
    final current = session;
    if (current == null) {
      throw StateError('当前没有监测会话');
    }
    _prepareCloudApi();

    if (!forceCreate && current.id.startsWith('session-')) {
      try {
        final remoteSession = await cloudApi.getSession(current.id);
        session = remoteSession;
        return remoteSession;
      } catch (error) {
        if (!_looksLikeMissingCloudSession(error)) {
          rethrow;
        }
        _pushEvent('当前云端会话已不存在，将重新创建');
      }
    }

    final cloudSession = await cloudApi.createSession(current);
    session = cloudSession;
    return cloudSession;
  }

  bool _looksLikeMissingCloudSession(Object error) {
    final text = error.toString();
    return text.contains('404') || text.contains('Session not found');
  }

  Future<void> _openCloudSessionForAutoUpload() async {
    final localSession = session;
    if (localSession == null) {
      return;
    }
    try {
      final cloudSession = await _ensureCloudSession();
      _segmentUploader.start(cloudSession);
      _pushEvent('自动分段上传已开启: ${cloudSession.userName}');
    } catch (error) {
      _segmentUploader.reset();
      _pushEvent('自动分段上传暂未开启: $error');
    }
  }

  Future<SegmentRecord> _uploadSegmentPayload(SegmentUploadPayload payload) async {
    _prepareCloudApi();
    pendingSegmentUploadCount = _segmentUploader.pendingCount;
    _scheduleNotify();
    try {
      return await cloudApi.uploadSegment(payload);
    } catch (error) {
      if (!_looksLikeMissingCloudSession(error)) {
        rethrow;
      }
      _pushEvent('云端会话不存在，正在重新创建并补传分段');
      final cloudSession = await _ensureCloudSession(forceCreate: true);
      final retargeted = SegmentUploadPayload(
        sessionId: cloudSession.id,
        deviceId: cloudSession.deviceId,
        userId: cloudSession.userId,
        userName: cloudSession.userName,
        segmentIndex: payload.segmentIndex,
        startTimestampMs: payload.startTimestampMs,
        endTimestampMs: payload.endTimestampMs,
        channels: payload.channels,
        metrics: payload.metrics,
        channelSummaries: payload.channelSummaries,
        metadata: payload.metadata,
      );
      return cloudApi.uploadSegment(retargeted);
    }
  }

  void _onSegmentUploaded(SegmentRecord segment) {
    latestSegment = segment;
    uploadedSegmentCount += 1;
    pendingSegmentUploadCount = _segmentUploader.pendingCount;
    _trimBuffersBefore(segment.endTimestampMs - _liveRetentionMs);
    _pushEvent('自动上传分段 #${segment.segmentIndex} 完成，样本 ${segment.sampleCount}');
    _scheduleNotify();
  }

  void _onSegmentUploadFailed(Object error) {
    failedSegmentUploadCount += 1;
    pendingSegmentUploadCount = _segmentUploader.pendingCount;
    _pushEvent('自动分段上传失败: $error');
    _scheduleNotify();
  }

  Map<String, dynamic> _buildSegmentMetrics() {
    final snapshot = localAnalysis;
    return <String, dynamic>{
      'durationSeconds': snapshot.durationSeconds,
      'meanQuality': snapshot.meanQuality,
      'activeChannels': snapshot.activeChannels,
      'uploadedSegmentCount': uploadedSegmentCount,
      'transportStats': transportStats.map((TransportStats item) => item.metadata).toList(),
      'localAnalysis': <String, dynamic>{
        'findings': snapshot.findings,
        'channels': snapshot.channels
            .map(
              (LocalChannelAnalysis item) => <String, dynamic>{
                'channelKey': item.channelKey,
                'sampleCount': item.sampleCount,
                'durationSeconds': item.durationSeconds,
                'meanQuality': item.meanQuality,
                'estimatedRateBpm': item.estimatedRateBpm,
              },
            )
            .toList(),
      },
      'physiologicalMetrics': snapshot.physio.toJson(),
    };
  }

  void _trimBuffersBefore(int timestampMs) {
    if (timestampMs <= 0 || isPaused) {
      return;
    }
    final currentWindowStartMs = _displayAnchorMs > 0
        ? _displayAnchorMs - (secondsPerScreen * 1000).round() - 3000
        : timestampMs;
    final safeTimestampMs = math.min(timestampMs, currentWindowStartMs);
    if (safeTimestampMs <= 0) {
      return;
    }
    for (final WaveformBuffer buffer in _buffers.values) {
      buffer.trimBefore(safeTimestampMs);
    }
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
    _channelCatalog = channels.map(_withDemoDefaults).toList(growable: false);
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
        userId: session!.userId,
        userName: session!.userName,
        metadata: session!.metadata,
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
      enabled: _isDefaultVisibleChannel(frame.channelKey) &&
          !_isStatusOnlyChannel(frame.channelKey),
    );
    _setCatalog(<ChannelDescriptor>[..._channelCatalog, inferred]);
  }

  ChannelDescriptor _withDemoDefaults(ChannelDescriptor channel) {
    final normalizedRate = _displaySampleRate(channel.key, channel.sampleRate);
    final normalized = normalizedRate != channel.sampleRate
        ? channel.copyWith(sampleRate: normalizedRate)
        : channel;
    if (_isDefaultVisibleChannel(normalized.key)) {
      return normalized.enabled ? normalized : normalized.copyWith(enabled: true);
    }
    if (_isStatusOnlyChannel(normalized.key) && normalized.enabled) {
      return normalized.copyWith(enabled: false);
    }
    return normalized;
  }

  bool _isDefaultVisibleChannel(String key) =>
      key == 'ecg_filtered' ||
      key == 'ppg_ir_filtered' ||
      key == 'ppg_red_filtered';

  bool _isEcgChannel(String key) => key == 'ecg' || key == 'ecg_filtered';

  bool _isImuChannel(String key) => key.startsWith('imu_') || key == 'imu';

  bool _isStatusOnlyChannel(String key) => _isImuChannel(key) || key == 'temp';

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

  SignalFrame? _normalizeFrameForLiveDisplay(SignalFrame frame) {
    if (frame.samples.isEmpty) {
      return null;
    }

    final previousDisplayTimestamp = _lastDisplayTimestampMsByChannel[frame.channelKey];
    final lastSeq = _lastAcceptedSeqByChannel[frame.channelKey];
    final incomingLatest = _latestFrameTimestampMs(frame);
    if (lastSeq != null &&
        frame.seq <= lastSeq &&
        previousDisplayTimestamp != null &&
        incomingLatest <= previousDisplayTimestamp) {
      return null;
    }

    final displayRate = _displaySampleRate(frame.channelKey, frame.sampleRate);
    final stepMs = math.max(1, (1000 / displayRate).round());
    final normalizedTimestamps = <int>[];
    final startTimestamp = previousDisplayTimestamp == null
        ? (frame.receivedAtMs > 0 ? frame.receivedAtMs : frame.timestampMs)
        : previousDisplayTimestamp + stepMs;
    for (var index = 0; index < frame.samples.length; index++) {
      normalizedTimestamps.add(startTimestamp + stepMs * index);
    }

    _lastDisplayTimestampMsByChannel[frame.channelKey] = normalizedTimestamps.last;
    _lastAcceptedSeqByChannel[frame.channelKey] = frame.seq;

    return SignalFrame(
      deviceId: frame.deviceId,
      sessionId: frame.sessionId,
      seq: frame.seq,
      timestampMs: normalizedTimestamps.first,
      channelKey: frame.channelKey,
      sampleRate: displayRate,
      unit: frame.unit,
      quality: frame.quality,
      samples: frame.samples,
      sampleTimestampsMs: normalizedTimestamps,
      transport: frame.transport,
      receivedAtMs: frame.receivedAtMs,
      sourceSeq: frame.sourceSeq,
      frameVersion: frame.frameVersion,
      decodeStatus: frame.decodeStatus,
    );
  }

  double _nominalDisplaySampleRate(String channelKey, double fallback) {
    if (channelKey.startsWith('ecg')) {
      return 500;
    }
    if (channelKey.startsWith('ppg')) {
      return 200;
    }
    return fallback > 0 ? fallback : 100;
  }

  double _displaySampleRate(String channelKey, double fallback) {
    if (mode == DataSourceMode.file) {
      return fallback > 0 ? fallback : 100;
    }
    return _nominalDisplaySampleRate(channelKey, fallback);
  }

  int _anchorTimestampForChannel(String channelKey) {
    if (isPaused) {
      return currentAnchorTimestampMs;
    }
    final store = _waveformStoreFor(channelKey);
    if (mode != DataSourceMode.file) {
      return _liveAnchorTimestampMs();
    }
    if (store != null && store.hasPoints) {
      return store.latestPointTimestampMs;
    }
    return currentAnchorTimestampMs;
  }

  Iterable<ChannelDescriptor> get _visibleWaveformChannels =>
      visibleChannels.where((ChannelDescriptor item) => !_isStatusOnlyChannel(item.key));

  bool _hasInitialVisibleBufferReady() {
    var hasCandidate = false;
    for (final ChannelDescriptor descriptor in _visibleWaveformChannels) {
      hasCandidate = true;
      final buffer = _buffers[descriptor.key];
      if (buffer == null || !buffer.hasPoints) {
        return false;
      }
      if (!_initiallyFilledChannels.contains(descriptor.key) &&
          buffer.activeLength < _initialSampleThreshold(descriptor)) {
        return false;
      }
    }
    return hasCandidate;
  }

  int _oldestReadyVisibleTimestampMs() {
    var oldest = 0;
    for (final ChannelDescriptor descriptor in _visibleWaveformChannels) {
      final buffer = _buffers[descriptor.key];
      if (buffer == null || !buffer.hasPoints) {
        continue;
      }
      if (!_initiallyFilledChannels.contains(descriptor.key) &&
          buffer.activeLength < _initialSampleThreshold(descriptor)) {
        continue;
      }
      oldest = oldest == 0 ? buffer.oldestTimestampMs : math.min(oldest, buffer.oldestTimestampMs);
    }
    return oldest;
  }

  int _latestReadyVisibleTimestampMs() {
    var latest = 0;
    for (final ChannelDescriptor descriptor in _visibleWaveformChannels) {
      final buffer = _buffers[descriptor.key];
      if (buffer == null || !buffer.hasPoints) {
        continue;
      }
      if (!_initiallyFilledChannels.contains(descriptor.key) &&
          buffer.activeLength < _initialSampleThreshold(descriptor)) {
        continue;
      }
      latest = latest == 0 ? buffer.latestPointTimestampMs : math.min(latest, buffer.latestPointTimestampMs);
    }
    return latest;
  }

  bool _shouldHoldChannelForInitialFill(String channelKey) {
    if (mode == DataSourceMode.file) {
      return false;
    }
    if (isPaused || _initiallyFilledChannels.contains(channelKey)) {
      return false;
    }
    final descriptor = _descriptorForChannel(channelKey);
    final buffer = _buffers[channelKey];
    if (descriptor == null || buffer == null || !buffer.hasPoints) {
      return mode != DataSourceMode.file;
    }
    return buffer.activeLength < _initialSampleThreshold(descriptor);
  }

  double _initialBufferProgress() {
    var progress = 1.0;
    var hasCandidate = false;
    for (final ChannelDescriptor descriptor in _visibleWaveformChannels) {
      hasCandidate = true;
      final buffer = _buffers[descriptor.key];
      if (buffer == null || !buffer.hasPoints) {
        progress = 0;
        continue;
      }
      final required = _initialSampleThreshold(descriptor);
      if (required <= 0) {
        continue;
      }
      progress = math.min(progress, buffer.activeLength / required);
    }
    return hasCandidate ? progress.clamp(0.0, 1.0).toDouble() : 0.0;
  }

  int _initialSampleThresholdForChannel(String channelKey) {
    final descriptor = _descriptorForChannel(channelKey);
    if (descriptor == null) {
      return math.max(96, (secondsPerScreen * 100).round());
    }
    return _initialSampleThreshold(descriptor);
  }

  int _initialSampleThreshold(ChannelDescriptor descriptor) {
    final rate = _displaySampleRate(descriptor.key, descriptor.sampleRate);
    final samplesForTarget = (rate * _initialBufferTargetSeconds).round();
    if (rate < 20) {
      return math.max(4, math.min(64, samplesForTarget));
    }
    return math.max(96, math.min(12000, samplesForTarget));
  }

  ChannelDescriptor? _descriptorForChannel(String channelKey) {
    for (final ChannelDescriptor descriptor in _channelCatalog) {
      if (descriptor.key == channelKey) {
        return descriptor;
      }
    }
    return null;
  }

  void _observeImuFrame(SignalFrame frame) {
    if (frame.samples.isEmpty) {
      return;
    }
    _latestImuValues[frame.channelKey] = frame.samples.last;
    _latestImuReceivedAtMs = frame.receivedAtMs > 0
        ? frame.receivedAtMs
        : DateTime.now().millisecondsSinceEpoch;
  }

  bool _acceptStatusTelemetryFrame(SignalFrame frame) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final previous = _lastStatusTelemetryAcceptedAtMs[frame.channelKey] ?? 0;
    final intervalMs = frame.channelKey == 'temp' ? 800 : 250;
    if (previous > 0 && now - previous < intervalMs) {
      return false;
    }
    _lastStatusTelemetryAcceptedAtMs[frame.channelKey] = now;
    return true;
  }

  void _observeTemperatureFrame(SignalFrame frame) {
    if (frame.samples.isEmpty) {
      return;
    }
    final value = frame.samples.last;
    if (value > 20 && value < 45) {
      _latestTemperatureCelsius = value;
    }
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
      physio: _computePhysio(),
    );
  }

  PhysiologicalMetrics _computePhysio() {
    double? heartRateBpm;
    double? hrvRmssd;
    double? hrvSdnn;
    double? hrvPnn50;
    double? respiratoryRateBpm;
    double? spo2Percent;
    double? temperatureCelsius;
    final notes = <String>[];

    // Heart rate & HRV from ECG R-R intervals via peak detection
    final ecgBuffer = _buffers['ecg_filtered'] ?? _buffers['ecg'];
    if (ecgBuffer != null && ecgBuffer.hasPoints) {
      final points = ecgBuffer.allPoints;
      if (points.length >= 50) {
        final rrIntervals = _detectRRIntervals(points);
        if (rrIntervals.length >= 3) {
          final meanRR = rrIntervals.reduce((a, b) => a + b) / rrIntervals.length;
          heartRateBpm = meanRR > 0 ? 60000.0 / meanRR : null;

          // SDNN
          final variance = rrIntervals.map((r) => math.pow(r - meanRR, 2)).reduce((a, b) => a + b) / rrIntervals.length;
          hrvSdnn = math.sqrt(variance);

          // RMSSD
          if (rrIntervals.length >= 2) {
            final diffs = <double>[];
            for (var i = 1; i < rrIntervals.length; i++) {
              diffs.add(math.pow(rrIntervals[i] - rrIntervals[i - 1], 2).toDouble());
            }
            hrvRmssd = math.sqrt(diffs.reduce((a, b) => a + b) / diffs.length);
          }

          // pNN50
          if (rrIntervals.length >= 2) {
            var count50 = 0;
            for (var i = 1; i < rrIntervals.length; i++) {
              if ((rrIntervals[i] - rrIntervals[i - 1]).abs() > 50) count50++;
            }
            hrvPnn50 = count50 / (rrIntervals.length - 1) * 100.0;
          }

          if (heartRateBpm != null && (heartRateBpm < 40 || heartRateBpm > 150)) {
            notes.add('心率估算值偏离正常范围，请检查信号质量');
          }
        }
      }
    }

    // Respiratory rate from PPG baseline wander (low-frequency modulation)
    final ppgBuffer = _buffers['ppg_ir_filtered'] ?? _buffers['ppg_ir'];
    if (ppgBuffer != null && ppgBuffer.hasPoints) {
      final points = ppgBuffer.allPoints;
      if (points.length >= 100) {
        respiratoryRateBpm = _estimateRespiratoryRate(points);
      }
    }

    // SpO2 estimate from PPG IR/Red ratio
    final ppgIrBuffer = _buffers['ppg_ir_filtered'] ?? _buffers['ppg_ir'];
    final ppgRedBuffer = _buffers['ppg_red_filtered'] ?? _buffers['ppg_red'];
    if (ppgIrBuffer != null && ppgRedBuffer != null &&
        ppgIrBuffer.hasPoints && ppgRedBuffer.hasPoints) {
      spo2Percent = _estimateSpO2(ppgIrBuffer, ppgRedBuffer);
    }

    // Temperature from temp channel
    final tempBuffer = _buffers['temp'];
    if (tempBuffer != null && tempBuffer.hasPoints) {
      final summary = tempBuffer.summary();
      final mean = _asNullableDouble(summary['mean']);
      if (mean != null && mean > 20 && mean < 45) {
        temperatureCelsius = mean;
      }
    }

    return PhysiologicalMetrics(
      heartRateBpm: heartRateBpm,
      hrvRmssd: hrvRmssd,
      hrvSdnn: hrvSdnn,
      hrvPnn50: hrvPnn50,
      respiratoryRateBpm: respiratoryRateBpm,
      spo2Percent: spo2Percent,
      temperatureCelsius: temperatureCelsius,
      notes: notes,
    );
  }

  // Simple threshold-based R-peak detector; returns RR intervals in ms
  List<double> _detectRRIntervals(List<SamplePoint> points) {
    if (points.length < 10) return const <double>[];
    final values = points.map((p) => p.value).toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) / values.length;
    final stdDev = math.sqrt(variance);
    final threshold = mean + stdDev * 0.6;

    final peaks = <int>[];
    const minPeakDistanceMs = 300; // ~200 BPM max
    for (var i = 1; i < points.length - 1; i++) {
      if (values[i] > threshold &&
          values[i] > values[i - 1] &&
          values[i] >= values[i + 1]) {
        if (peaks.isEmpty ||
            points[i].timestampMs - points[peaks.last].timestampMs >= minPeakDistanceMs) {
          peaks.add(i);
        }
      }
    }

    if (peaks.length < 2) return const <double>[];
    final rrIntervals = <double>[];
    for (var i = 1; i < peaks.length; i++) {
      final rr = (points[peaks[i]].timestampMs - points[peaks[i - 1]].timestampMs).toDouble();
      if (rr >= 300 && rr <= 2000) rrIntervals.add(rr); // 30–200 BPM range
    }
    return rrIntervals;
  }

  // Estimate respiratory rate from PPG baseline wander via zero-crossing count
  double? _estimateRespiratoryRate(List<SamplePoint> points) {
    if (points.length < 50) return null;
    final durationSeconds = (points.last.timestampMs - points.first.timestampMs) / 1000.0;
    if (durationSeconds < 5) return null;

    // Downsample to ~4 Hz for respiratory band
    final step = math.max(1, (points.length / (durationSeconds * 4)).round());
    final downsampled = <double>[];
    for (var i = 0; i < points.length; i += step) {
      downsampled.add(points[i].value);
    }

    // Simple moving average to extract baseline (respiratory component)
    const windowSize = 8;
    final baseline = <double>[];
    for (var i = 0; i < downsampled.length; i++) {
      final start = math.max(0, i - windowSize ~/ 2);
      final end = math.min(downsampled.length, i + windowSize ~/ 2 + 1);
      final window = downsampled.sublist(start, end);
      baseline.add(window.reduce((a, b) => a + b) / window.length);
    }

    // Count zero crossings of baseline
    var crossings = 0;
    for (var i = 1; i < baseline.length; i++) {
      if ((baseline[i - 1] < 0 && baseline[i] >= 0) ||
          (baseline[i - 1] >= 0 && baseline[i] < 0)) {
        crossings++;
      }
    }

    final breathsPerMinute = (crossings / 2.0) / (durationSeconds / 60.0);
    if (breathsPerMinute < 4 || breathsPerMinute > 40) return null;
    return breathsPerMinute;
  }

  // SpO2 estimate using ratio-of-ratios: R = (AC_red/DC_red) / (AC_ir/DC_ir)
  // SpO2 ≈ 110 - 25*R (empirical calibration curve)
  double? _estimateSpO2(WaveformBuffer irBuffer, WaveformBuffer redBuffer) {
    final irSummary = irBuffer.summary();
    final redSummary = redBuffer.summary();
    final irMean = _asNullableDouble(irSummary['mean']);
    final irRms = _asNullableDouble(irSummary['rms']);
    final redMean = _asNullableDouble(redSummary['mean']);
    final redRms = _asNullableDouble(redSummary['rms']);
    if (irMean == null || irRms == null || redMean == null || redRms == null) return null;
    if (irMean <= 0 || redMean <= 0) return null;

    // AC component approximated as RMS of AC-coupled signal
    final irAC = math.sqrt(math.max(0, irRms * irRms - irMean * irMean));
    final redAC = math.sqrt(math.max(0, redRms * redRms - redMean * redMean));
    if (irAC <= 0 || redAC <= 0) return null;

    final r = (redAC / redMean) / (irAC / irMean);
    final spo2 = 110.0 - 25.0 * r;
    if (spo2 < 70 || spo2 > 100) return null;
    return spo2;
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
    _notifyTimer = Timer(const Duration(milliseconds: 100), notifyListeners);
  }

  void _markFrameDirty() {
    _hasPendingFrameNotify = true;
  }

  int _liveAnchorTimestampMs() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final synchronizedLatestMs = _latestReadyVisibleTimestampMs();
    final liveLatestMs = synchronizedLatestMs > 0 ? synchronizedLatestMs : latestTimestampMs;
    if (liveLatestMs == 0) {
      return nowMs;
    }
    if (mode != DataSourceMode.file && !_hasInitialVisibleBufferReady()) {
      return liveLatestMs;
    }

    if (_displayAnchorMs == 0) {
      _livePlaybackStartAnchorMs = _oldestReadyVisibleTimestampMs();
      _displayAnchorMs = _livePlaybackStartAnchorMs == 0
          ? liveLatestMs - (_targetPlaybackLagSeconds * 1000).round()
          : _livePlaybackStartAnchorMs;
      _lastAnchorWallMs = nowMs;
      return _displayAnchorMs;
    }

    final rawElapsedMs = _lastAnchorWallMs == 0 ? 0 : nowMs - _lastAnchorWallMs;
    final elapsedMs = rawElapsedMs < 0 ? 0 : math.min(250, rawElapsedMs);
    _lastAnchorWallMs = nowMs;

    final targetAnchor = liveLatestMs - (_targetPlaybackLagSeconds * 1000).round();
    final maxAnchor = liveLatestMs - 120;
    var next = _displayAnchorMs;
    final fillUntil = _livePlaybackStartAnchorMs == 0
        ? 0
        : _livePlaybackStartAnchorMs + (secondsPerScreen * 1000).round();
    if (fillUntil > 0 && next < fillUntil) {
      next += elapsedMs;
    } else if (targetAnchor > next + 500) {
      next += math.min(250, elapsedMs * 3);
    } else {
      next += elapsedMs;
    }
    if (maxAnchor <= _displayAnchorMs) {
      // If transport/UI stalls consume the buffer, keep the current anchor.
      // Moving the anchor backwards makes the waveform vanish and restart
      // from the right edge, which is exactly the jump we want to avoid.
      return _displayAnchorMs;
    }
    if (next > maxAnchor) {
      next = maxAnchor;
    }
    if (next < _displayAnchorMs) {
      next = _displayAnchorMs;
    }
    _displayAnchorMs = next;
    return _displayAnchorMs;
  }

  void _startAgentCheck() {
    _stopAgentCheck();
    agentStatus.state = AgentState.idle;
    agentStatus.riskLevel = null;
    agentStatus.confidence = null;
    agentStatus.summary = '';
    agentStatus.notificationText = '';
    agentStatus.lastAlertRiskLevel = null;
    agentStatus.isAlertAcknowledged = false;
    _agentLastAnalyzedSegmentId = null;
    _agentCheckTimer = Timer.periodic(
      MonitoringAgentStatus.agentCheckInterval,
      (_) => _agentAutoAnalyze(),
    );
    _pushEvent('长期监测 Agent 已启动');
    _scheduleNotify();
  }

  void _stopAgentCheck() {
    _agentCheckTimer?.cancel();
    _agentCheckTimer = null;
    agentStatus.state = AgentState.idle;
    _scheduleNotify();
  }

  Future<void> _agentAutoAnalyze() async {
    if (!_agentAutoAnalyzeEnabled) return;
    final segment = latestSegment;
    final localSession = session;
    if (segment == null || localSession == null) {
      if (agentStatus.state != AgentState.idle) {
        agentStatus.state = AgentState.idle;
        agentStatus.summary = '等待数据上传';
        _scheduleNotify();
      }
      return;
    }
    if (segment.id == _agentLastAnalyzedSegmentId) return;

    _agentLastAnalyzedSegmentId = segment.id;
    agentStatus.state = AgentState.analyzing;
    agentStatus.summary = '正在分析分段 #${segment.segmentIndex}...';
    _pushEvent('Agent 自动分析分段 #${segment.segmentIndex}');
    _scheduleNotify();

    try {
      _prepareCloudApi();
      final agentReport = await cloudApi.analyzeSegment(
        sessionId: localSession.id,
        segmentId: segment.id,
      );
      agentStatus.lastAnalysisTime = DateTime.now();
      agentStatus.riskLevel = agentReport.riskLevel;
      agentStatus.confidence = agentReport.confidence;
      agentStatus.summary = agentReport.summary;
      agentStatus.error = '';

      final isRuleFallback = agentReport.summary.contains('未启用大模型');

      switch (agentReport.riskLevel) {
        case 'high':
          agentStatus.state = AgentState.highRisk;
          agentStatus.notificationText = _buildNotificationText(agentReport);
          // Only auto-publish a visible report when the risk is high.
          // For medium / low / normal results the agent updates its
          // internal status but does not surface a report card — the
          // user can still manually trigger "upload + analyze" for a
          // full report at any time.
          report = agentReport;
          if (agentStatus.shouldShowAlert()) {
            agentStatus.markAlertShown();
            _pushEvent('Agent 高风险预警：${agentReport.summary}');
          }
          break;
        case 'medium':
          agentStatus.state = AgentState.warning;
          agentStatus.notificationText = isRuleFallback ? '' : _buildNotificationText(agentReport);
          break;
        default:
          agentStatus.state = AgentState.normal;
          agentStatus.notificationText = '';
      }
    } catch (error) {
      agentStatus.state = AgentState.error;
      agentStatus.error = error.toString();
      agentStatus.summary = '分析失败';
      _pushEvent('Agent 自动分析失败: $error');
    }
    _scheduleNotify();
  }

  String _buildNotificationText(MedicalReport r) {
    final buffer = StringBuffer();
    buffer.writeln('【心肺监测辅助预警通知】');
    buffer.writeln();
    buffer.writeln('风险等级：${r.riskLevel == 'high' ? '高风险' : r.riskLevel == 'medium' ? '中风险' : '低风险'}');
    if (r.confidence != null) {
      buffer.writeln('置信度：${(r.confidence! * 100).toStringAsFixed(0)}%');
    }
    buffer.writeln();
    buffer.writeln('综合结论：${r.summary}');
    if (r.findings.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('主要发现：');
      for (final f in r.findings.take(3)) {
        buffer.writeln('· ${f.title}：${f.detail}');
      }
    }
    buffer.writeln();
    buffer.writeln('此为辅助预警，不构成医疗诊断。建议及时联系本人/就医/呼叫急救。');
    return buffer.toString();
  }

  void acknowledgeAgentAlert() {
    agentStatus.acknowledgeAlert();
    _scheduleNotify();
  }

  void toggleAgentAutoAnalyze(bool enabled) {
    _agentAutoAnalyzeEnabled = enabled;
    if (!enabled) {
      _stopAgentCheck();
    } else if (isConnected) {
      _startAgentCheck();
    }
    _scheduleNotify();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _uiTickTimer?.cancel();
    _agentCheckTimer?.cancel();
    _frameSubscription?.cancel();
    _statusSubscription?.cancel();
    _catalogSubscription?.cancel();
    _statsSubscription?.cancel();
    _segmentUploader.dispose();
    _mqttAdapter.dispose();
    _fileAdapter.dispose();
    _bluetoothAdapter.dispose();
    waveformNotifier.dispose();
    cloudApi.dispose();
    super.dispose();
  }
}

class ImuDisplaySnapshot {
  const ImuDisplaySnapshot({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.accMagnitude,
    required this.gyroMagnitude,
    required this.motionLevel,
    required this.motionLabel,
    required this.receivedAtMs,
  });

  factory ImuDisplaySnapshot.fromValues({
    required Map<String, double> values,
    required int receivedAtMs,
  }) {
    final ax = values['imu_ax'] ?? 0;
    final ay = values['imu_ay'] ?? 0;
    final az = values['imu_az'] ?? 0;
    final gx = values['imu_gx'] ?? 0;
    final gy = values['imu_gy'] ?? 0;
    final gz = values['imu_gz'] ?? 0;
    final accMagnitude = math.sqrt(ax * ax + ay * ay + az * az);
    final gyroMagnitude = math.sqrt(gx * gx + gy * gy + gz * gz);
    final accDeltaFromGravity = (accMagnitude - 16384.0).abs();
    final motionLevel =
        values['imu_motion'] ?? math.max(gyroMagnitude, accDeltaFromGravity);
    return ImuDisplaySnapshot(
      ax: ax,
      ay: ay,
      az: az,
      gx: gx,
      gy: gy,
      gz: gz,
      accMagnitude: accMagnitude,
      gyroMagnitude: gyroMagnitude,
      motionLevel: motionLevel,
      motionLabel: _motionLabel(motionLevel),
      receivedAtMs: receivedAtMs,
    );
  }

  static String _motionLabel(double level) {
    if (level >= 6000) {
      return '剧烈运动';
    }
    if (level >= 2500) {
      return '明显运动';
    }
    if (level >= 800) {
      return '轻微运动';
    }
    return '平稳';
  }

  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double accMagnitude;
  final double gyroMagnitude;
  final double motionLevel;
  final String motionLabel;
  final int receivedAtMs;

  bool get hasData => receivedAtMs > 0;
}

class AutoSegmentUploader {
  AutoSegmentUploader({
    required this.onUpload,
    required this.onUploaded,
    required this.onFailed,
    required this.buildMetrics,
  });

  static const int segmentDurationSeconds = 20;
  static const int _segmentDurationMs = segmentDurationSeconds * 1000;
  static const int _segmentCloseGraceMs = 2500;
  static const int _maxPendingSegments = 3;
  static const int _minAutoUploadSamples = 100;

  final Future<SegmentRecord> Function(SegmentUploadPayload payload) onUpload;
  final void Function(SegmentRecord segment) onUploaded;
  final void Function(Object error) onFailed;
  final Map<String, dynamic> Function() buildMetrics;

  final Map<int, _SegmentAccumulator> _segments = <int, _SegmentAccumulator>{};
  final Set<int> _closedSegmentIndexes = <int>{};
  final List<SegmentUploadPayload> _queue = <SegmentUploadPayload>[];
  SessionRecord? _session;
  bool _isUploading = false;
  int? _baseTimestampMs;
  int _maxObservedTimestampMs = 0;

  int get pendingCount => _queue.length + (_isUploading ? 1 : 0);

  void start(SessionRecord session) {
    _session = session;
  }

  void reset() {
    _segments.clear();
    _closedSegmentIndexes.clear();
    _queue.clear();
    _session = null;
    _baseTimestampMs = null;
    _maxObservedTimestampMs = 0;
    _isUploading = false;
  }

  void observeFrame(SignalFrame frame) {
    final session = _session;
    if (session == null || frame.samples.isEmpty) {
      return;
    }
    _baseTimestampMs ??= frame.timestampMs;
    final base = _baseTimestampMs!;
    final stepMs = frame.sampleRate <= 0 ? 1 : (1000 / frame.sampleRate).round();
    final timestamps = frame.sampleTimestampsMs;

    for (var index = 0; index < frame.samples.length; index++) {
      final timestampMs = timestamps != null && index < timestamps.length
          ? timestamps[index]
          : frame.timestampMs + stepMs * index;
      final segmentIndex = math.max(0, (timestampMs - base) ~/ _segmentDurationMs);
      if (_closedSegmentIndexes.contains(segmentIndex)) {
        continue;
      }
      _maxObservedTimestampMs = math.max(_maxObservedTimestampMs, timestampMs);
      final segmentStart = base + segmentIndex * _segmentDurationMs;
      final segmentEnd = segmentStart + _segmentDurationMs - 1;
      final accumulator = _segments.putIfAbsent(
        segmentIndex,
        () => _SegmentAccumulator(
          segmentIndex: segmentIndex,
          startTimestampMs: segmentStart,
          endTimestampMs: segmentEnd,
        ),
      );
      accumulator.addSample(frame, timestampMs, frame.samples[index]);
    }

    final closeBeforeMs = _maxObservedTimestampMs - _segmentCloseGraceMs;
    final readyIndexes = _segments.entries
        .where((MapEntry<int, _SegmentAccumulator> item) => item.value.endTimestampMs <= closeBeforeMs)
        .map((MapEntry<int, _SegmentAccumulator> item) => item.key)
        .toList()
      ..sort();
    for (final int index in readyIndexes) {
      _sealSegment(index, session);
    }
    unawaited(_pumpUploads());
  }

  Future<void> flush() async {
    final session = _session;
    if (session != null) {
      final indexes = _segments.keys.toList()..sort();
      for (final int index in indexes) {
        _sealSegment(index, session);
      }
    }
    await _pumpUploads();
  }

  void dispose() {
    reset();
  }

  void _sealSegment(int index, SessionRecord session) {
    if (!_closedSegmentIndexes.add(index)) {
      _segments.remove(index);
      return;
    }
    final accumulator = _segments.remove(index);
    if (accumulator == null || accumulator.isEmpty) {
      return;
    }
    if (accumulator.sampleCount < _minAutoUploadSamples) {
      return;
    }
    final payload = accumulator.toPayload(
      session: session,
      metrics: buildMetrics(),
    );
    _queue.add(payload);
    while (_queue.length > _maxPendingSegments) {
      _queue.removeAt(0);
      onFailed('待上传分段超过 $_maxPendingSegments 段，已丢弃最旧分段');
    }
  }

  Future<void> _pumpUploads() async {
    if (_isUploading) {
      return;
    }
    _isUploading = true;
    try {
      while (_queue.isNotEmpty) {
        final payload = _queue.removeAt(0);
        try {
          final record = await onUpload(payload);
          onUploaded(record);
        } catch (error) {
          onFailed(error);
          _queue.insert(0, payload);
          while (_queue.length > _maxPendingSegments) {
            _queue.removeLast();
          }
          break;
        }
      }
    } finally {
      _isUploading = false;
    }
  }
}

class _SegmentAccumulator {
  _SegmentAccumulator({
    required this.segmentIndex,
    required this.startTimestampMs,
    required this.endTimestampMs,
  });

  final int segmentIndex;
  final int startTimestampMs;
  final int endTimestampMs;
  final Map<String, _SegmentChannelAccumulator> channels =
      <String, _SegmentChannelAccumulator>{};

  bool get isEmpty => channels.values.every((_SegmentChannelAccumulator item) => item.samples.isEmpty);
  int get sampleCount => channels.values.fold<int>(
        0,
        (int total, _SegmentChannelAccumulator item) => total + item.samples.length,
      );

  void addSample(SignalFrame frame, int timestampMs, double value) {
    channels
        .putIfAbsent(
          frame.channelKey,
          () => _SegmentChannelAccumulator(
            channelKey: frame.channelKey,
            sampleRate: frame.sampleRate,
            unit: frame.unit,
          ),
        )
        .add(timestampMs, value, frame.quality);
  }

  SegmentUploadPayload toPayload({
    required SessionRecord session,
    required Map<String, dynamic> metrics,
  }) {
    final channelUploads = channels.values
        .where((_SegmentChannelAccumulator item) => item.samples.isNotEmpty)
        .map((_SegmentChannelAccumulator item) => item.toUpload())
        .toList(growable: false);
    return SegmentUploadPayload(
      sessionId: session.id,
      deviceId: session.deviceId,
      userId: session.userId,
      userName: session.userName,
      segmentIndex: segmentIndex,
      startTimestampMs: startTimestampMs,
      endTimestampMs: endTimestampMs,
      channels: channelUploads,
      metrics: metrics,
      channelSummaries: <String, dynamic>{
        for (final SegmentChannelUpload item in channelUploads)
          item.channelKey: item.summary,
      },
      metadata: <String, dynamic>{
        'source': 'flutter_upper_auto_segment',
        'durationSeconds': AutoSegmentUploader.segmentDurationSeconds,
      },
    );
  }
}

class _SegmentChannelAccumulator {
  _SegmentChannelAccumulator({
    required this.channelKey,
    required this.sampleRate,
    required this.unit,
  });

  final String channelKey;
  final double sampleRate;
  final String unit;
  final List<double> samples = <double>[];
  int? firstTimestampMs;
  int? lastTimestampMs;
  double _qualitySum = 0;
  double _sum = 0;
  double _sumSquares = 0;
  double? _min;
  double? _max;

  void add(int timestampMs, double value, double quality) {
    firstTimestampMs ??= timestampMs;
    lastTimestampMs = timestampMs;
    samples.add(value);
    _qualitySum += quality;
    _sum += value;
    _sumSquares += value * value;
    _min = _min == null ? value : math.min(_min!, value);
    _max = _max == null ? value : math.max(_max!, value);
  }

  SegmentChannelUpload toUpload() {
    final count = samples.length;
    final mean = count == 0 ? 0.0 : _sum / count;
    final rms = count == 0 ? 0.0 : math.sqrt(_sumSquares / count);
    final variance = count == 0 ? 0.0 : math.max(0, (_sumSquares / count) - mean * mean);
    final minValue = _min ?? 0.0;
    final maxValue = _max ?? 0.0;
    return SegmentChannelUpload(
      channelKey: channelKey,
      sampleRate: sampleRate,
      unit: unit,
      quality: count == 0 ? 0 : _qualitySum / count,
      startTimestampMs: firstTimestampMs ?? 0,
      endTimestampMs: lastTimestampMs ?? firstTimestampMs ?? 0,
      samples: List<double>.unmodifiable(samples),
      summary: <String, dynamic>{
        'samples': count,
        'mean': mean,
        'min': minValue,
        'max': maxValue,
        'rms': rms,
        'stdDev': math.sqrt(variance),
        'peakToPeak': maxValue - minValue,
        'meanQuality': count == 0 ? 0 : _qualitySum / count,
      },
    );
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

  List<SamplePoint> get allPoints =>
      hasPoints ? _points.sublist(_startIndex) : const <SamplePoint>[];

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
    // 60 s of 250-Hz ECG ≈ 15 000 points; 60000 was ~4× more than a 20-s window needs.
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

  void trimBefore(int timestampMs) {
    if (!hasPoints || timestampMs <= oldestTimestampMs) {
      return;
    }
    final trimEnd = _lowerBound(timestampMs);
    if (trimEnd <= _startIndex) {
      return;
    }
    var needsRangeRebuild = false;
    for (var index = _startIndex; index < trimEnd; index++) {
      final item = _points[index];
      _sum -= item.value;
      _sumSquares -= item.value * item.value;
      if (item.value == _min || item.value == _max) {
        needsRangeRebuild = true;
      }
    }
    _startIndex = trimEnd;
    _summaryDirty = true;
    if (!hasPoints) {
      _points.clear();
      _startIndex = 0;
      _sum = 0;
      _sumSquares = 0;
      _min = 0;
      _max = 0;
      _cachedSummary = null;
      _cachedRateBpm = null;
      _lastRateEstimateTimestampMs = 0;
      return;
    }
    if (needsRangeRebuild) {
      _recomputeRange();
    }
    if (_startIndex >= 12000) {
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

