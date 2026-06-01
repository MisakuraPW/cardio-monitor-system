// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use, uri_does_not_exist
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

const List<String> _statusTelemetryChannelKeys = <String>[
  'imu_ax',
  'imu_ay',
  'imu_az',
  'imu_gx',
  'imu_gy',
  'imu_gz',
  'temp',
];

abstract class DataSourceAdapter {
  Stream<SignalFrame> get streamFrames;
  Stream<AdapterStatus> get streamStatus;
  Stream<List<ChannelDescriptor>> get streamCatalog;
  Stream<TransportStats> get streamTransportStats;

  Future<void> connect();
  Future<void> disconnect();
  Future<void> updateChannels(List<ChannelDescriptor> channels);
  Future<void> sendControl(ControlCommand command);
  void dispose();
}

class MqttAdapterConfig {
  MqttAdapterConfig({
    this.host = '182.254.220.56',
    this.port = 8083,
    this.path = '/mqtt',
    this.useTls = false,
    this.deviceId = 'esp32-bio',
    this.username = '',
    this.password = '',
    this.demoMode = true,
  });

  String host;
  int port;
  String path;
  bool useTls;
  String deviceId;
  String username;
  String password;
  bool demoMode;
}

class BluetoothAdapterConfig {
  BluetoothAdapterConfig({
    this.deviceNamePrefix = 'esp32-bio',
    this.serviceUuid = 'c0ad0001-8d2b-4d6f-9a1c-1c8a52f0a001',
    this.notifyCharacteristicUuid = 'c0ad1001-8d2b-4d6f-9a1c-1c8a52f0a001',
    this.controlCharacteristicUuid = 'c0ad1002-8d2b-4d6f-9a1c-1c8a52f0a001',
  });

  String deviceNamePrefix;
  String serviceUuid;
  String notifyCharacteristicUuid;
  String controlCharacteristicUuid;
}

class _Bio1DecodedBatch {
  const _Bio1DecodedBatch({
    required this.frames,
    required this.channels,
  });

  final List<SignalFrame> frames;
  final List<ChannelDescriptor> channels;

  bool get isEmpty => frames.isEmpty && channels.isEmpty;
}

class _Bio1BinaryCodec {
  static const int _bio1HeaderLength = 11;
  static const int _bio2HeaderLength = 19;
  static const int _bio3HeaderLength = 20;

  static _Bio1DecodedBatch decode(
    Uint8List bytes, {
    required String deviceId,
    required String sessionId,
    String transport = 'binary',
  }) {
    final frames = <SignalFrame>[];
    final channels = <String, ChannelDescriptor>{};
    var cursor = 0;

    while (cursor <= bytes.length - _bio1HeaderLength) {
      final bio1Index = _indexOfMagic(bytes, cursor, 0x31);
      final bio2Index = _indexOfMagic(bytes, cursor, 0x32);
      final bio3Index = _indexOfMagic(bytes, cursor, 0x33);
      final magicIndex = _firstNonNegative3(bio1Index, bio2Index, bio3Index);
      if (magicIndex < 0 || magicIndex + _bio1HeaderLength > bytes.length) {
        break;
      }

      final isBio2 = bio2Index >= 0 && bio2Index == magicIndex;
      final isBio3 = bio3Index >= 0 && bio3Index == magicIndex;
      final headerLength = isBio3
          ? _bio3HeaderLength
          : isBio2
              ? _bio2HeaderLength
              : _bio1HeaderLength;
      if (magicIndex + headerLength > bytes.length) {
        break;
      }

      if (isBio3) {
        final header = ByteData.sublistView(bytes, magicIndex, magicIndex + headerLength);
        final seq = header.getUint32(6, Endian.little);
        final ecgCount = header.getUint16(10, Endian.little);
        final ppgCount = header.getUint16(12, Endian.little);
        final payloadLength = header.getUint16(14, Endian.little);
        final expectedPayloadLength = ecgCount * 12 + ppgCount * 16;
        final frameLength = headerLength + payloadLength;
        if ((ecgCount == 0 && ppgCount == 0) || magicIndex + frameLength > bytes.length) {
          break;
        }
        if (payloadLength != expectedPayloadLength) {
          cursor = magicIndex + 1;
          continue;
        }

        var decodeStatus = 'ok';
        final expectedCrc = header.getUint32(16, Endian.little);
        final actualCrc = _crc32(bytes, magicIndex + headerLength, payloadLength);
        if (actualCrc != expectedCrc) {
          decodeStatus = 'crc_error';
        }

        final data = ByteData.sublistView(bytes, magicIndex, magicIndex + frameLength);
        if (ecgCount > 0) {
          _decodeEcg(
            data,
            seq: seq,
            sampleCount: ecgCount,
            sampleSize: 12,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: 3,
            decodeStatus: decodeStatus,
            transport: transport,
          );
        }
        if (ppgCount > 0) {
          _decodePpg(
            data,
            seq: seq,
            sampleCount: ppgCount,
            sampleSize: 16,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength + ecgCount * 12,
            frameVersion: 3,
            decodeStatus: decodeStatus,
            transport: transport,
          );
        }
        cursor = magicIndex + frameLength;
        continue;
      }

      final typeByte = bytes[magicIndex + (isBio2 ? 5 : 4)];
      final sampleSize = _sampleSizeForType(typeByte);
      if (sampleSize == null) {
        cursor = magicIndex + 1;
        continue;
      }

      final header = ByteData.sublistView(bytes, magicIndex, magicIndex + headerLength);
      final seq = isBio2
          ? header.getUint32(7, Endian.little)
          : header.getUint32(5, Endian.little);
      final sampleCount = isBio2
          ? header.getUint16(11, Endian.little)
          : header.getUint16(9, Endian.little);
      final payloadLength = isBio2
          ? header.getUint16(13, Endian.little)
          : sampleCount * sampleSize;
      final frameLength = headerLength + payloadLength;
      if (sampleCount == 0 || magicIndex + frameLength > bytes.length) {
        break;
      }
      if (payloadLength != sampleCount * sampleSize) {
        cursor = magicIndex + 1;
        continue;
      }

      final frameVersion = isBio2 ? bytes[magicIndex + 4] : 1;
      var decodeStatus = 'ok';
      if (isBio2) {
        final expectedCrc = header.getUint32(15, Endian.little);
        final actualCrc = _crc32(bytes, magicIndex + headerLength, payloadLength);
        if (actualCrc != expectedCrc) {
          decodeStatus = 'crc_error';
        }
      }

      final data = ByteData.sublistView(
        bytes,
        magicIndex,
        magicIndex + frameLength,
      );
      switch (String.fromCharCode(typeByte)) {
        case 'E':
          _decodeEcg(
            data,
            seq: seq,
            sampleCount: sampleCount,
            sampleSize: sampleSize,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
          );
          break;
        case 'F':
          _decodeEcg(
            data,
            seq: seq,
            sampleCount: sampleCount,
            sampleSize: sampleSize,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
            channelKey: 'ecg_filtered',
            label: 'ECG Filtered',
            colorHex: '#D94F70',
          );
          break;
        case 'P':
          _decodePpg(
            data,
            seq: seq,
            sampleCount: sampleCount,
            sampleSize: sampleSize,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
          );
          break;
        case 'Q':
          _decodePpg(
            data,
            seq: seq,
            sampleCount: sampleCount,
            sampleSize: sampleSize,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
            irKey: 'ppg_ir_filtered',
            redKey: 'ppg_red_filtered',
            irLabel: 'PPG IR Filtered',
            redLabel: 'PPG RED Filtered',
          );
          break;
        case 'I':
          _decodeImu(
            data,
            seq: seq,
            sampleCount: sampleCount,
            sampleSize: sampleSize,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
          );
          break;
        case 'T':
          _decodeTemp(
            data,
            seq: seq,
            sampleCount: sampleCount,
            deviceId: deviceId,
            sessionId: sessionId,
            frames: frames,
            channels: channels,
            payloadOffset: headerLength,
            frameVersion: frameVersion,
            decodeStatus: decodeStatus,
            transport: transport,
          );
          break;
      }

      cursor = magicIndex + frameLength;
    }

    return _Bio1DecodedBatch(
      frames: frames,
      channels: channels.values.toList(growable: false),
    );
  }

  static bool looksLikeBio1(Uint8List bytes) =>
      _indexOfMagic(bytes, 0, 0x31) >= 0 ||
      _indexOfMagic(bytes, 0, 0x32) >= 0 ||
      _indexOfMagic(bytes, 0, 0x33) >= 0;

  static void _decodeEcg(
    ByteData data, {
    required int seq,
    required int sampleCount,
    required int sampleSize,
    required String deviceId,
    required String sessionId,
    required List<SignalFrame> frames,
    required Map<String, ChannelDescriptor> channels,
    required int payloadOffset,
    required int frameVersion,
    required String decodeStatus,
    required String transport,
    String channelKey = 'ecg',
    String label = 'ECG',
    String colorHex = '#F25F5C',
  }) {
    final timestampsUs = <int>[];
    final values = <double>[];
    var qualitySum = 0.0;
    for (var index = 0; index < sampleCount; index++) {
      final offset = payloadOffset + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      values.add(data.getUint16(offset + 8, Endian.little).toDouble());
      if (sampleSize >= 12) {
        if (channelKey == 'ecg_filtered') {
          final flags = data.getUint8(offset + 10);
          final qualityByte = data.getUint8(offset + 11);
          qualitySum += flags == 0 ? qualityByte / 100.0 : 0.0;
        } else {
          final leadOff = data.getUint8(offset + 10) != 0 ||
              data.getUint8(offset + 11) != 0;
          qualitySum += leadOff ? 0.0 : 1.0;
        }
      } else {
        qualitySum += 1.0;
      }
    }
    final sampleRate = _estimateSampleRate(timestampsUs, 500);
    final quality = sampleCount == 0 ? 1.0 : qualitySum / sampleCount;
    channels[channelKey] = _channel(
      key: channelKey,
      label: label,
      unit: 'adc',
      colorHex: colorHex,
      sampleRate: sampleRate,
    );
    frames.add(
      _frame(
        deviceId: deviceId,
        sessionId: sessionId,
        channelKey: channelKey,
        seq: seq,
        unit: 'adc',
        sampleRate: sampleRate,
        timestampsUs: timestampsUs,
        samples: values,
        quality: quality,
        transport: transport,
        frameVersion: frameVersion,
        decodeStatus: decodeStatus,
      ),
    );
  }

  static void _decodePpg(
    ByteData data, {
    required int seq,
    required int sampleCount,
    required int sampleSize,
    required String deviceId,
    required String sessionId,
    required List<SignalFrame> frames,
    required Map<String, ChannelDescriptor> channels,
    required int payloadOffset,
    required int frameVersion,
    required String decodeStatus,
    required String transport,
    String irKey = 'ppg_ir',
    String redKey = 'ppg_red',
    String irLabel = 'PPG IR',
    String redLabel = 'PPG RED',
  }) {
    final timestampsUs = <int>[];
    final irValues = <double>[];
    final redValues = <double>[];
    for (var index = 0; index < sampleCount; index++) {
      final offset = payloadOffset + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      irValues.add(data.getUint32(offset + 8, Endian.little).toDouble());
      redValues.add(data.getUint32(offset + 12, Endian.little).toDouble());
    }
    final sampleRate = _estimateSampleRate(timestampsUs, 200);
    channels[irKey] = _channel(
      key: irKey,
      label: irLabel,
      unit: 'count',
      colorHex: '#247BA0',
      sampleRate: sampleRate,
    );
    channels[redKey] = _channel(
      key: redKey,
      label: redLabel,
      unit: 'count',
      colorHex: '#C84C5A',
      sampleRate: sampleRate,
    );
    frames
      ..add(
        _frame(
          deviceId: deviceId,
          sessionId: sessionId,
          channelKey: irKey,
          seq: seq,
          unit: 'count',
          sampleRate: sampleRate,
          timestampsUs: timestampsUs,
          samples: irValues,
          transport: transport,
          frameVersion: frameVersion,
          decodeStatus: decodeStatus,
        ),
      )
      ..add(
        _frame(
          deviceId: deviceId,
          sessionId: sessionId,
          channelKey: redKey,
          seq: seq,
          unit: 'count',
          sampleRate: sampleRate,
          timestampsUs: timestampsUs,
          samples: redValues,
          transport: transport,
          frameVersion: frameVersion,
          decodeStatus: decodeStatus,
        ),
      );
  }

  static void _decodeImu(
    ByteData data, {
    required int seq,
    required int sampleCount,
    required int sampleSize,
    required String deviceId,
    required String sessionId,
    required List<SignalFrame> frames,
    required Map<String, ChannelDescriptor> channels,
    required int payloadOffset,
    required int frameVersion,
    required String decodeStatus,
    required String transport,
  }) {
    final timestampsUs = <int>[];
    final channelSamples = <String, List<double>>{
      'imu_ax': <double>[],
      'imu_ay': <double>[],
      'imu_az': <double>[],
      'imu_gx': <double>[],
      'imu_gy': <double>[],
      'imu_gz': <double>[],
    };
    for (var index = 0; index < sampleCount; index++) {
      final offset = payloadOffset + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      channelSamples['imu_ax']!.add(data.getInt16(offset + 8, Endian.little).toDouble());
      channelSamples['imu_ay']!.add(data.getInt16(offset + 10, Endian.little).toDouble());
      channelSamples['imu_az']!.add(data.getInt16(offset + 12, Endian.little).toDouble());
      channelSamples['imu_gx']!.add(data.getInt16(offset + 14, Endian.little).toDouble());
      channelSamples['imu_gy']!.add(data.getInt16(offset + 16, Endian.little).toDouble());
      channelSamples['imu_gz']!.add(data.getInt16(offset + 18, Endian.little).toDouble());
    }

    final sampleRate = _estimateSampleRate(timestampsUs, 100);
    const metadata = <String, (String, String)>{
      'imu_ax': ('IMU AX', '#2A9D8F'),
      'imu_ay': ('IMU AY', '#36B7A1'),
      'imu_az': ('IMU AZ', '#55C7AE'),
      'imu_gx': ('IMU GX', '#7B6DFF'),
      'imu_gy': ('IMU GY', '#9A7CFF'),
      'imu_gz': ('IMU GZ', '#B792FF'),
    };
    for (final entry in channelSamples.entries) {
      final info = metadata[entry.key]!;
      channels[entry.key] = _channel(
        key: entry.key,
        label: info.$1,
        unit: 'raw',
        colorHex: info.$2,
        sampleRate: sampleRate,
      );
      frames.add(
        _frame(
          deviceId: deviceId,
          sessionId: sessionId,
          channelKey: entry.key,
          seq: seq,
          unit: 'raw',
          sampleRate: sampleRate,
          timestampsUs: timestampsUs,
          samples: entry.value,
          transport: transport,
          frameVersion: frameVersion,
          decodeStatus: decodeStatus,
        ),
      );
    }
  }

  // BIO2 'T' frame: each sample is 8B ts_us + 2B raw + 4B float temp_c + 1B flags = 15B
  static void _decodeTemp(
    ByteData data, {
    required int seq,
    required int sampleCount,
    required String deviceId,
    required String sessionId,
    required List<SignalFrame> frames,
    required Map<String, ChannelDescriptor> channels,
    required int payloadOffset,
    required int frameVersion,
    required String decodeStatus,
    required String transport,
  }) {
    const int sampleSize = 15;
    final timestampsUs = <int>[];
    final tempValues = <double>[];
    for (var index = 0; index < sampleCount; index++) {
      final offset = payloadOffset + index * sampleSize;
      if (offset + sampleSize > data.lengthInBytes) break;
      timestampsUs.add(_readUint64Le(data, offset));
      // float32 little-endian at offset+10
      final rawBytes = Uint8List(4);
      rawBytes[0] = data.getUint8(offset + 10);
      rawBytes[1] = data.getUint8(offset + 11);
      rawBytes[2] = data.getUint8(offset + 12);
      rawBytes[3] = data.getUint8(offset + 13);
      tempValues.add(ByteData.sublistView(rawBytes).getFloat32(0, Endian.little).toDouble());
    }
    if (timestampsUs.isEmpty) return;
    final sampleRate = _estimateSampleRate(timestampsUs, 1.0);
    channels['temp'] = _channel(
      key: 'temp',
      label: '体温',
      unit: '°C',
      colorHex: '#E76F51',
      sampleRate: sampleRate,
    );
    frames.add(
      _frame(
        deviceId: deviceId,
        sessionId: sessionId,
        channelKey: 'temp',
        seq: seq,
        unit: '°C',
        sampleRate: sampleRate,
        timestampsUs: timestampsUs,
        samples: tempValues,
        transport: transport,
        frameVersion: frameVersion,
        decodeStatus: decodeStatus,
      ),
    );
  }

  static SignalFrame _frame({
    required String deviceId,
    required String sessionId,
    required String channelKey,
    required int seq,
    required String unit,
    required double sampleRate,
    required List<int> timestampsUs,
    required List<double> samples,
    double quality = 1.0,
    required String transport,
    required int frameVersion,
    required String decodeStatus,
  }) {
    final sampleTimestampsMs = timestampsUs
        .map((int timestampUs) => timestampUs ~/ 1000)
        .toList(growable: false);
    return SignalFrame(
      deviceId: deviceId,
      sessionId: sessionId,
      seq: seq,
      timestampMs: sampleTimestampsMs.first,
      channelKey: channelKey,
      sampleRate: sampleRate,
      unit: unit,
      quality: quality,
      samples: samples,
      sampleTimestampsMs: sampleTimestampsMs,
      transport: transport,
      receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      sourceSeq: seq,
      frameVersion: frameVersion,
      decodeStatus: decodeStatus,
    );
  }

  static ChannelDescriptor _channel({
    required String key,
    required String label,
    required String unit,
    required String colorHex,
    required double sampleRate,
  }) {
    return ChannelDescriptor(
      key: key,
      label: label,
      unit: unit,
      sampleRate: sampleRate,
      colorHex: colorHex,
      enabled: true,
    );
  }

  static int? _sampleSizeForType(int typeByte) {
    switch (String.fromCharCode(typeByte)) {
      case 'E':
      case 'F':
        return 12;
      case 'P':
      case 'Q':
        return 16;
      case 'I':
        return 20;
      case 'T':
        return 15;
      default:
        return null;
    }
  }

  static int _indexOfMagic(Uint8List bytes, int start, int versionByte) {
    for (var index = start; index <= bytes.length - 4; index++) {
      if (bytes[index] == 0x42 &&
          bytes[index + 1] == 0x49 &&
          bytes[index + 2] == 0x4F &&
          bytes[index + 3] == versionByte) {
        return index;
      }
    }
    return -1;
  }

  static int _firstNonNegative(int a, int b) {
    if (a < 0) {
      return b;
    }
    if (b < 0) {
      return a;
    }
    return a < b ? a : b;
  }

  static int _firstNonNegative3(int a, int b, int c) {
    final first = _firstNonNegative(a, b);
    return _firstNonNegative(first, c);
  }

  static int _crc32(Uint8List bytes, int offset, int length) {
    var crc = 0xFFFFFFFF;
    for (var index = offset; index < offset + length; index++) {
      crc ^= bytes[index];
      for (var bit = 0; bit < 8; bit++) {
        final mask = -(crc & 1);
        crc = (crc >> 1) ^ (0xEDB88320 & mask);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static int _readUint64Le(ByteData data, int offset) {
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    return high * 0x100000000 + low;
  }

  static double _estimateSampleRate(List<int> timestampsUs, double fallback) {
    if (timestampsUs.length < 2) {
      return fallback;
    }
    var totalDelta = 0;
    var count = 0;
    for (var index = 1; index < timestampsUs.length; index++) {
      final delta = timestampsUs[index] - timestampsUs[index - 1];
      if (delta > 0) {
        totalDelta += delta;
        count++;
      }
    }
    if (count == 0 || totalDelta <= 0) {
      return fallback;
    }
    return 1000000.0 / (totalDelta / count);
  }
}

class MqttDataSourceAdapter implements DataSourceAdapter {
  MqttDataSourceAdapter(this.config);

  final MqttAdapterConfig config;
  final StreamController<SignalFrame> _frameController =
      StreamController<SignalFrame>.broadcast();
  final StreamController<AdapterStatus> _statusController =
      StreamController<AdapterStatus>.broadcast();
  final StreamController<List<ChannelDescriptor>> _catalogController =
      StreamController<List<ChannelDescriptor>>.broadcast();
  final StreamController<TransportStats> _statsController =
      StreamController<TransportStats>.broadcast();
  final Uuid _uuid = const Uuid();

  MqttBrowserClient? _client;
  List<ChannelDescriptor> catalog = const <ChannelDescriptor>[];
  String _binarySessionId = 'mqtt-session';
  bool _hasSeenBinaryPayload = false;

  String get _baseTopic => 'cardio/${config.deviceId}';

  @override
  Stream<SignalFrame> get streamFrames => _frameController.stream;

  @override
  Stream<AdapterStatus> get streamStatus => _statusController.stream;

  @override
  Stream<List<ChannelDescriptor>> get streamCatalog => _catalogController.stream;

  @override
  Stream<TransportStats> get streamTransportStats => _statsController.stream;

  @override
  Future<void> connect() async {
    await disconnect();
    _emitStatus(AdapterState.connecting, '正在连接 MQTT Broker...');

    final protocol = config.useTls ? 'wss' : 'ws';
    final endpoint = '$protocol://${config.host}${config.path}';
    final clientId = 'flutter-web-${_uuid.v4().substring(0, 8)}';
    _binarySessionId = 'mqtt-${DateTime.now().millisecondsSinceEpoch}';
    _hasSeenBinaryPayload = false;

    final client = MqttBrowserClient.withPort(endpoint, clientId, config.port);
    client.setProtocolV311();
    client.keepAlivePeriod = 20;
    client.connectTimeoutPeriod = 2000;
    client.disconnectOnNoResponsePeriod = 6;
    client.logging(on: false);
    client.websocketProtocols = const <String>['mqtt'];
    client.onConnected = () {
      _emitStatus(AdapterState.connected, 'MQTT 连接已建立');
    };
    client.onDisconnected = () {
      _emitStatus(AdapterState.disconnected, 'MQTT 连接已断开');
    };
    client.onFailedConnectionAttempt = (int attemptNumber) {
      _emitStatus(
        AdapterState.connecting,
        'MQTT 正在重试连接 ($attemptNumber/3): $endpoint',
      );
    };
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();

    html.window.console.log(
      '[MQTT] connecting endpoint=$endpoint clientId=$clientId deviceId=${config.deviceId}',
    );

    try {
      if (config.username.isNotEmpty) {
        await client.connect(
          config.username,
          config.password.isEmpty ? null : config.password,
        );
      } else {
        await client.connect();
      }
    } catch (error) {
      _emitStatus(AdapterState.error, 'MQTT 连接失败: $error');
      rethrow;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      final state = client.connectionStatus?.state.toString() ?? 'unknown';
      _emitStatus(AdapterState.error, 'MQTT 未连接成功: $state');
      throw Exception('MQTT connection failed: $state');
    }

    _client = client;
    client.subscribe('$_baseTopic/status', MqttQos.atLeastOnce);
    if (config.demoMode) {
      client.subscribe('$_baseTopic/waveform_bin/ecg_filtered', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/waveform_bin/ppg_filtered', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/waveform_bin/imu', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/waveform_bin/temp', MqttQos.atMostOnce);
    } else {
      client.subscribe('$_baseTopic/catalog', MqttQos.atLeastOnce);
      client.subscribe('$_baseTopic/waveform/+', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/waveform_bin/+', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/bin/+', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/telemetry_bin', MqttQos.atMostOnce);
      client.subscribe('$_baseTopic/binary', MqttQos.atMostOnce);
    }
    client.subscribe('$_baseTopic/metrics', MqttQos.atLeastOnce);
    client.subscribe('$_baseTopic/alerts', MqttQos.atLeastOnce);
    client.subscribe('$_baseTopic/temperature', MqttQos.atMostOnce);
    if (config.demoMode) {
      await sendControl(
        const ControlCommand(
          type: 'set_channels',
          payload: <String, dynamic>{
            'enabledKeys': <String>[
              'ecg_filtered',
              'ppg_ir_filtered',
              'ppg_red_filtered',
              ..._statusTelemetryChannelKeys,
            ],
          },
        ),
      );
    }
    client.updates?.listen(_handleUpdates);

    _emitStatus(AdapterState.streaming, '正在监听 $_baseTopic/#');
  }

  @override
  Future<void> disconnect() async {
    _client?.disconnect();
    _client = null;
  }

  @override
  Future<void> updateChannels(List<ChannelDescriptor> channels) async {
    catalog = List<ChannelDescriptor>.from(channels);
    final enabledKeys = channels
        .where((ChannelDescriptor item) => item.enabled)
        .map((ChannelDescriptor item) => item.key)
        .where((String key) => !config.demoMode || _isDemoRealtimeChannel(key))
        .toList();
    if (config.demoMode) {
      enabledKeys.addAll(_statusTelemetryChannelKeys);
    }
    await sendControl(
      ControlCommand(
        type: 'set_channels',
        payload: <String, dynamic>{'enabledKeys': enabledKeys.toSet().toList()},
      ),
    );
  }

  @override
  Future<void> sendControl(ControlCommand command) async {
    final client = _client;
    if (client == null) {
      return;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addUTF8String(jsonEncode(command.toJson()));
    client.publishMessage(
      '$_baseTopic/control',
      MqttQos.atLeastOnce,
      builder.payload!,
    );
  }

  void _handleUpdates(List<MqttReceivedMessage<MqttMessage>>? events) {
    if (events == null) {
      return;
    }
    for (final MqttReceivedMessage<MqttMessage> event in events) {
      final topic = event.topic;
      final publishMessage = event.payload as MqttPublishMessage;
      final payloadBytes = Uint8List.fromList(publishMessage.payload.message);
      if (_tryHandleBinaryPayload(topic, payloadBytes)) {
        continue;
      }
      final payload = MqttPublishPayload.bytesToStringAsString(
        publishMessage.payload.message,
      );
      if (payload.trim().isEmpty) {
        continue;
      }

      final Map<String, dynamic> jsonMap;
      try {
        jsonMap = jsonDecode(payload) as Map<String, dynamic>;
      } catch (error) {
        _emitStatus(AdapterState.error, 'MQTT payload parse failed on $topic');
        continue;
      }
      if (topic.endsWith('/catalog')) {
        final rawChannels =
            (jsonMap['channels'] as List<dynamic>? ?? const <dynamic>[]);
        catalog = rawChannels
            .map(
              (dynamic item) =>
                  ChannelDescriptor.fromJson(item as Map<String, dynamic>),
            )
            .toList();
        _catalogController.add(List<ChannelDescriptor>.from(catalog));
        _emitStatus(
          AdapterState.streaming,
          '已收到通道目录更新，共 ${catalog.length} 个通道',
        );
        continue;
      }

      if (topic.contains('/waveform/')) {
        final frameJson = <String, dynamic>{...jsonMap};
        if (!frameJson.containsKey('channelKey')) {
          frameJson['channelKey'] = topic.split('/').last;
        }
        frameJson['transport'] = frameJson['transport'] ?? 'mqtt_json';
        frameJson['receivedAtMs'] = DateTime.now().millisecondsSinceEpoch;
        frameJson['sourceSeq'] = frameJson['sourceSeq'] ?? frameJson['seq'];
        _frameController.add(SignalFrame.fromJson(frameJson));
        continue;
      }

      if (topic.endsWith('/status')) {
        final message = (jsonMap['message'] ?? '设备状态更新').toString();
        _emitStatus(AdapterState.streaming, message);
        continue;
      }

      if (topic.endsWith('/metrics')) {
        _statsController.add(TransportStats.fromMqttMetrics(jsonMap));
        continue;
      }

      if (topic.endsWith('/alerts')) {
        final message = (jsonMap['message'] ?? '收到报警事件').toString();
        _emitStatus(AdapterState.error, message);
      }

      if (topic.endsWith('/temperature')) {
        _handleTemperatureJson(jsonMap);
      }
    }
  }

  void _handleTemperatureJson(Map<String, dynamic> json) {
    final rawSamples = json['samples'] as List<dynamic>? ?? const <dynamic>[];
    if (rawSamples.isEmpty) return;
    final sampleRate = (json['sampleRate'] as num?)?.toDouble() ?? 1.0;
    final baseTimestampMs = (json['timestampMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final seq = (json['seq'] as num?)?.toInt() ?? 0;
    final deviceId = (json['deviceId'] ?? _binarySessionId).toString();
    final sessionId = _binarySessionId;

    final tempValues = <double>[];
    final timestamps = <int>[];
    for (final dynamic item in rawSamples) {
      if (item is Map<String, dynamic>) {
        final tempC = (item['tempC'] as num?)?.toDouble();
        final tsUs = (item['tsUs'] as num?)?.toInt();
        if (tempC != null) {
          tempValues.add(tempC);
          timestamps.add(tsUs != null ? tsUs ~/ 1000 : baseTimestampMs);
        }
      }
    }
    if (tempValues.isEmpty) return;

    _mergeBinaryCatalog(<ChannelDescriptor>[
      ChannelDescriptor(
        key: 'temp',
        label: '体温',
        unit: '°C',
        sampleRate: sampleRate,
        colorHex: '#E76F51',
        enabled: true,
      ),
    ]);
    _frameController.add(SignalFrame(
      deviceId: deviceId,
      sessionId: sessionId,
      seq: seq,
      timestampMs: timestamps.first,
      channelKey: 'temp',
      sampleRate: sampleRate,
      unit: '°C',
      quality: 1.0,
      samples: tempValues,
      sampleTimestampsMs: timestamps,
      transport: 'mqtt_json',
      receivedAtMs: DateTime.now().millisecondsSinceEpoch,
      sourceSeq: seq,
    ));
  }

  bool _tryHandleBinaryPayload(String topic, Uint8List payloadBytes) {
    if (!_Bio1BinaryCodec.looksLikeBio1(payloadBytes)) {
      return false;
    }

    final batch = _Bio1BinaryCodec.decode(
      payloadBytes,
      deviceId: config.deviceId,
      sessionId: _binarySessionId,
      transport: 'mqtt_binary',
    );
    if (batch.isEmpty) {
      _emitStatus(AdapterState.error, 'MQTT BIO frame parse failed on $topic');
      return true;
    }

    final incomingChannels = config.demoMode
        ? batch.channels
            .where((ChannelDescriptor item) => _isDemoRealtimeChannel(item.key))
            .toList(growable: false)
        : batch.channels;
    _mergeBinaryCatalog(incomingChannels);
    for (final SignalFrame frame in batch.frames) {
      if (config.demoMode && !_isDemoRealtimeChannel(frame.channelKey)) {
        continue;
      }
      _frameController.add(frame);
    }
    if (!_hasSeenBinaryPayload) {
      _hasSeenBinaryPayload = true;
      _emitStatus(
        AdapterState.streaming,
        'MQTT BIO binary stream active, ${catalog.length} channels',
      );
    }
    return true;
  }

  bool _isDemoRealtimeChannel(String key) =>
      key == 'ecg_filtered' ||
      key == 'ppg_ir_filtered' ||
      key == 'ppg_red_filtered' ||
      key.startsWith('imu_') ||
      key == 'temp';

  void _mergeBinaryCatalog(List<ChannelDescriptor> incoming) {
    if (incoming.isEmpty) {
      return;
    }
    var changed = false;
    final nextCatalog = List<ChannelDescriptor>.from(catalog);
    for (final ChannelDescriptor descriptor in incoming) {
      final index = nextCatalog.indexWhere(
        (ChannelDescriptor item) => item.key == descriptor.key,
      );
      if (index < 0) {
        nextCatalog.add(descriptor);
        changed = true;
        continue;
      }
      final existing = nextCatalog[index];
      final updated = existing.copyWith(
        label: descriptor.label,
        unit: descriptor.unit,
        colorHex: descriptor.colorHex,
      );
      if (updated.label != existing.label ||
          updated.unit != existing.unit ||
          updated.colorHex != existing.colorHex) {
        nextCatalog[index] = updated;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    catalog = nextCatalog;
    _catalogController.add(List<ChannelDescriptor>.from(catalog));
  }

  void _emitStatus(AdapterState state, String message) {
    _statusController.add(
      AdapterStatus(
        state: state,
        message: message,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _frameController.close();
    _statusController.close();
    _catalogController.close();
    _statsController.close();
  }
}

class FileReplayAdapter implements DataSourceAdapter {
  FileReplayAdapter();

  final StreamController<SignalFrame> _frameController =
      StreamController<SignalFrame>.broadcast();
  final StreamController<AdapterStatus> _statusController =
      StreamController<AdapterStatus>.broadcast();
  final StreamController<List<ChannelDescriptor>> _catalogController =
      StreamController<List<ChannelDescriptor>>.broadcast();
  final StreamController<TransportStats> _statsController =
      StreamController<TransportStats>.broadcast();
  final Uuid _uuid = const Uuid();

  final List<String> _palette = const <String>[
    '#F25F5C',
    '#247BA0',
    '#70C1B3',
    '#FF9F1C',
    '#6A4C93',
    '#0F4C5C',
  ];

  List<SignalFrame> _frames = <SignalFrame>[];
  Timer? _timer;
  DateTime? _replayStartAt;
  int _cursor = 0;
  Set<String> _enabledKeys = <String>{};

  List<ChannelDescriptor> parsedChannels = const <ChannelDescriptor>[];
  String replayFileName = '';

  bool get isLoaded => _frames.isNotEmpty;

  @override
  Stream<SignalFrame> get streamFrames => _frameController.stream;

  @override
  Stream<AdapterStatus> get streamStatus => _statusController.stream;

  @override
  Stream<List<ChannelDescriptor>> get streamCatalog => _catalogController.stream;

  @override
  Stream<TransportStats> get streamTransportStats => _statsController.stream;

  Future<void> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: const <String>['csv', 'json'],
    );
    if (result == null || result.files.isEmpty) {
      return;
    }
    await loadPlatformFile(result.files.single);
  }

  Future<void> loadPlatformFile(PlatformFile file) async {
    final bytes = file.bytes;
    if (bytes == null) {
      throw Exception('文件内容为空，Web 模式下请启用 withData');
    }

    replayFileName = file.name;
    final extension = file.extension?.toLowerCase() ?? '';
    if (extension == 'json') {
      await _loadJson(bytes);
    } else {
      await _loadCsv(bytes);
    }

    _enabledKeys = parsedChannels
        .where((ChannelDescriptor item) => item.enabled)
        .map((ChannelDescriptor item) => item.key)
        .toSet();
    _catalogController.add(List<ChannelDescriptor>.from(parsedChannels));
    _emitStatus(
      AdapterState.idle,
      '已载入文件 $replayFileName，共 ${parsedChannels.length} 个通道，${_frames.length} 帧',
    );
  }

  @override
  Future<void> connect() async {
    if (_frames.isEmpty) {
      _emitStatus(AdapterState.error, '请先选择 CSV 或 JSON 文件');
      throw Exception('Replay file is not loaded.');
    }

    await disconnect();
    _cursor = 0;
    _replayStartAt = DateTime.now();
    _emitStatus(AdapterState.streaming, '文件回放已开始');
    _timer = Timer.periodic(const Duration(milliseconds: 20), _onTick);
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    if (_frames.isNotEmpty) {
      _emitStatus(AdapterState.disconnected, '文件回放已停止');
    }
  }

  @override
  Future<void> updateChannels(List<ChannelDescriptor> channels) async {
    parsedChannels = List<ChannelDescriptor>.from(channels);
    _enabledKeys = channels
        .where((ChannelDescriptor item) => item.enabled)
        .map((ChannelDescriptor item) => item.key)
        .toSet();
  }

  @override
  Future<void> sendControl(ControlCommand command) async {
    _emitStatus(AdapterState.streaming, '文件回放忽略控制指令: ${command.type}');
  }

  void _onTick(Timer timer) {
    if (_replayStartAt == null || _frames.isEmpty) {
      return;
    }

    final baseTimestamp = _frames.first.timestampMs;
    final elapsedMs = DateTime.now().difference(_replayStartAt!).inMilliseconds;
    while (_cursor < _frames.length) {
      final frame = _frames[_cursor];
      final relativeMs = frame.timestampMs - baseTimestamp;
      if (relativeMs > elapsedMs) {
        break;
      }
      if (_enabledKeys.isEmpty || _enabledKeys.contains(frame.channelKey)) {
        _frameController.add(frame);
      }
      _cursor++;
    }

    if (_cursor >= _frames.length) {
      _timer?.cancel();
      _emitStatus(AdapterState.disconnected, '文件回放完成');
    }
  }

  Future<void> _loadCsv(Uint8List bytes) async {
    final text = utf8.decode(bytes);
    final lines = const LineSplitter()
        .convert(text)
        .where((String line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) {
      throw Exception('CSV 至少需要包含表头和一行数据');
    }

    final headers = _splitCsvLine(lines.first);
    final timestampIndex = headers.indexWhere(
      (String item) =>
          item.toLowerCase() == 'timestamp_ms' ||
          item.toLowerCase() == 'time_ms' ||
          item.toLowerCase() == 'time',
    );
    if (timestampIndex < 0) {
      throw Exception('CSV 缺少时间戳列，建议使用 timestamp_ms');
    }

    final channelColumns = <int, String>{};
    for (var index = 0; index < headers.length; index++) {
      if (index == timestampIndex) {
        continue;
      }
      channelColumns[index] = headers[index];
    }

    final timestamps = <int>[];
    final columns = <String, List<double>>{};
    for (final String header in channelColumns.values) {
      columns[header] = <double>[];
    }

    for (final String line in lines.skip(1)) {
      final parts = _splitCsvLine(line);
      if (parts.length != headers.length) {
        continue;
      }
      timestamps.add(int.parse(parts[timestampIndex]));
      channelColumns.forEach((int index, String header) {
        final value = double.tryParse(parts[index]) ?? 0;
        columns[header]!.add(value);
      });
    }

    if (timestamps.length < 2) {
      throw Exception('CSV 数据行过少，无法推断采样率');
    }

    final delta = timestamps[1] - timestamps[0];
    final sampleRate = delta <= 0 ? 100.0 : 1000.0 / delta;
    parsedChannels = <ChannelDescriptor>[];
    var colorIndex = 0;
    for (final entry in columns.entries) {
      final normalized = _normalizeHeader(entry.key);
      parsedChannels = <ChannelDescriptor>[
        ...parsedChannels,
        ChannelDescriptor(
          key: normalized.key,
          label: normalized.label,
          unit: normalized.unit,
          sampleRate: sampleRate,
          colorHex: _palette[colorIndex % _palette.length],
          enabled: true,
        ),
      ];
      colorIndex++;
    }

    _frames = _buildBatchedFrames(
      deviceId: 'file-device-${_uuid.v4().substring(0, 8)}',
      sessionId: 'file-session-${_uuid.v4().substring(0, 8)}',
      timestamps: timestamps,
      columns: columns,
      channelDescriptors: parsedChannels,
    );
  }

  Future<void> _loadJson(Uint8List bytes) async {
    final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final rawChannels =
        (decoded['channels'] as List<dynamic>? ?? const <dynamic>[]);
    final rawFrames = (decoded['frames'] as List<dynamic>? ?? const <dynamic>[]);
    parsedChannels = rawChannels
        .map(
          (dynamic item) =>
              ChannelDescriptor.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    _frames = rawFrames
        .map(
          (dynamic item) => SignalFrame.fromJson(item as Map<String, dynamic>),
        )
        .toList()
      ..sort(
        (SignalFrame a, SignalFrame b) => a.timestampMs.compareTo(b.timestampMs),
      );

    if (parsedChannels.isEmpty && _frames.isNotEmpty) {
      final channels = <String, ChannelDescriptor>{};
      for (final SignalFrame frame in _frames) {
        channels[frame.channelKey] = ChannelDescriptor(
          key: frame.channelKey,
          label: frame.channelKey.toUpperCase(),
          unit: frame.unit,
          sampleRate: frame.sampleRate,
          colorHex: _palette[channels.length % _palette.length],
          enabled: true,
        );
      }
      parsedChannels = channels.values.toList();
    }
  }

  List<SignalFrame> _buildBatchedFrames({
    required String deviceId,
    required String sessionId,
    required List<int> timestamps,
    required Map<String, List<double>> columns,
    required List<ChannelDescriptor> channelDescriptors,
  }) {
    final frames = <SignalFrame>[];
    var seq = 0;

    for (final ChannelDescriptor descriptor in channelDescriptors) {
      final key = columns.keys.firstWhere(
        (String item) => _normalizeHeader(item).key == descriptor.key,
      );
      final values = columns[key]!;
      const batchSize = 10;

      for (var offset = 0; offset < values.length; offset += batchSize) {
        final end = offset + batchSize > values.length
            ? values.length
            : offset + batchSize;
        frames.add(
          SignalFrame(
            deviceId: deviceId,
            sessionId: sessionId,
            seq: seq++,
            timestampMs: timestamps[offset],
            channelKey: descriptor.key,
            sampleRate: descriptor.sampleRate,
            unit: descriptor.unit,
            quality: 0.92,
            samples: values.sublist(offset, end),
            sampleTimestampsMs: timestamps.sublist(offset, end),
          ),
        );
      }
    }

    frames.sort(
      (SignalFrame a, SignalFrame b) => a.timestampMs.compareTo(b.timestampMs),
    );
    return frames;
  }

  List<String> _splitCsvLine(String line) {
    return line.split(',').map((String item) => item.trim()).toList();
  }

  _NormalizedChannel _normalizeHeader(String header) {
    final segments =
        header.split('_').where((String part) => part.isNotEmpty).toList();
    if (segments.isEmpty) {
      return const _NormalizedChannel(
        key: 'channel',
        label: 'CHANNEL',
        unit: 'a.u.',
      );
    }
    final unit = segments.length > 1 ? segments.last : 'a.u.';
    final key = segments.first.toLowerCase();
    final label = segments.first.toUpperCase();
    return _NormalizedChannel(key: key, label: label, unit: unit);
  }

  void _emitStatus(AdapterState state, String message) {
    _statusController.add(
      AdapterStatus(
        state: state,
        message: message,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _frameController.close();
    _statusController.close();
    _catalogController.close();
    _statsController.close();
  }
}

class BluetoothDataSourceAdapter implements DataSourceAdapter {
  BluetoothDataSourceAdapter(this.config);

  final BluetoothAdapterConfig config;
  final StreamController<SignalFrame> _frameController =
      StreamController<SignalFrame>.broadcast();
  final StreamController<AdapterStatus> _statusController =
      StreamController<AdapterStatus>.broadcast();
  final StreamController<List<ChannelDescriptor>> _catalogController =
      StreamController<List<ChannelDescriptor>>.broadcast();
  final StreamController<TransportStats> _statsController =
      StreamController<TransportStats>.broadcast();

  dynamic _device;
  dynamic _server;
  dynamic _service;
  dynamic _notifyCharacteristic;
  dynamic _controlCharacteristic;
  dynamic _notificationCallback;
  dynamic _disconnectCallback;
  final List<int> _receiveBuffer = <int>[];
  List<ChannelDescriptor> _currentCatalog = const <ChannelDescriptor>[];
  String _deviceId = 'esp32-bio';
  String _sessionId = 'ble-session';
  bool _manualDisconnecting = false;
  int _autoReconnectAttempts = 0;

  @override
  Stream<SignalFrame> get streamFrames => _frameController.stream;

  @override
  Stream<AdapterStatus> get streamStatus => _statusController.stream;

  @override
  Stream<List<ChannelDescriptor>> get streamCatalog => _catalogController.stream;

  @override
  Stream<TransportStats> get streamTransportStats => _statsController.stream;

  @override
  Future<void> connect() async {
    _manualDisconnecting = true;
    await disconnect();
    _manualDisconnecting = false;
    // Give the ESP32 BLE stack time to fully release the previous connection.
    // Without this, the device may still be cleaning up and reject the new
    // GATT handshake with "NetworkError: GATT Server is disconnected" or
    // "NotSupportedError: GATT operation failed for unknown reason".
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _emitStatus(AdapterState.connecting, '正在请求蓝牙设备访问权限...');

    final bluetooth = js_util.getProperty(html.window.navigator, 'bluetooth');
    if (bluetooth == null) {
      _emitStatus(AdapterState.error, '当前浏览器不支持 Web Bluetooth，请使用 Chrome/Edge 并通过 HTTPS 或 localhost 打开网页');
      throw Exception('Web Bluetooth is not available.');
    }

    final options = _buildRequestOptions();

    // ── Phase 1: device picker ──────────────────────────────────────
    try {
      _device = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(bluetooth, 'requestDevice', <dynamic>[options]),
      );

      _disconnectCallback = js_util.allowInterop((dynamic _) {
        if (_manualDisconnecting) {
          _emitStatus(AdapterState.disconnected, '蓝牙设备已断开');
          return;
        }
        unawaited(_tryAutoReconnect());
      });
      js_util.callMethod(
        _device,
        'addEventListener',
        <dynamic>['gattserverdisconnected', _disconnectCallback],
      );
    } catch (error) {
      _emitStatus(AdapterState.error, '未选择蓝牙设备: $error');
      rethrow;
    }

    // ── Phase 2: GATT connect + service discovery (with retries) ────
    const maxAttempts = 3;
    var attempt = 0;
    Object? lastError;

    while (attempt < maxAttempts) {
      attempt++;
      try {
        // Small stagger before each GATT attempt
        if (attempt > 1) {
          await Future<void>.delayed(
              Duration(milliseconds: 400 * attempt));
        }

        final gatt = js_util.getProperty(_device, 'gatt');
        _emitStatus(AdapterState.connecting,
            '正在建立 GATT 连接 (第 $attempt 次)...');
        _server = await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(gatt, 'connect', const <dynamic>[]),
        );

        _service = await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            _server,
            'getPrimaryService',
            <dynamic>[config.serviceUuid],
          ),
        );

        _notifyCharacteristic = await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            _service,
            'getCharacteristic',
            <dynamic>[config.notifyCharacteristicUuid],
          ),
        );

        _controlCharacteristic = await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            _service,
            'getCharacteristic',
            <dynamic>[config.controlCharacteristicUuid],
          ),
        );

        await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            _notifyCharacteristic,
            'startNotifications',
            const <dynamic>[],
          ),
        );

        // All GATT steps succeeded — exit retry loop
        lastError = null;
        break;
      } catch (error) {
        lastError = error;
        // Clean up partial GATT state before retrying
        try {
          if (_server != null) {
            js_util.callMethod(_server, 'disconnect', const <dynamic>[]);
          }
        } catch (_) {}
        _server = null;
        _service = null;
        _notifyCharacteristic = null;
        _controlCharacteristic = null;

        if (attempt < maxAttempts) {
          _emitStatus(AdapterState.connecting,
              'GATT 连接失败，${400 * attempt}ms 后重试 ($attempt/$maxAttempts)');
        }
      }
    }

    if (lastError != null) {
      _emitStatus(
          AdapterState.error, '蓝牙 GATT 连接失败（已重试 $maxAttempts 次）: $lastError');
      throw lastError;
    }

    // ── Phase 3: wire up notifications ──────────────────────────────
    _notificationCallback = js_util.allowInterop((dynamic event) {
      _handleNotification(event);
    });
    js_util.callMethod(
      _notifyCharacteristic,
      'addEventListener',
      <dynamic>['characteristicvaluechanged', _notificationCallback],
    );

    _receiveBuffer.clear();
    _currentCatalog = const <ChannelDescriptor>[];
    final deviceName =
        (js_util.getProperty(_device, 'name') ?? config.deviceNamePrefix)
            .toString()
            .trim();
    _deviceId = deviceName.isEmpty ? config.deviceNamePrefix : deviceName;
    _sessionId = 'ble-${DateTime.now().millisecondsSinceEpoch}';
    _autoReconnectAttempts = 0;
    _emitStatus(
        AdapterState.streaming, '蓝牙已连接: $_deviceId，等待 BIO1 二进制数据...');
  }

  Future<void> _tryAutoReconnect() async {
    if (_device == null || _autoReconnectAttempts >= 2) {
      _emitStatus(AdapterState.disconnected, '蓝牙设备已断开，请重新连接');
      return;
    }
    _autoReconnectAttempts += 1;
    _emitStatus(AdapterState.connecting, '蓝牙短暂断开，正在自动重连...');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    try {
      final gatt = js_util.getProperty(_device, 'gatt');
      _server = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(gatt, 'connect', const <dynamic>[]),
      );
      _service = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(
          _server,
          'getPrimaryService',
          <dynamic>[config.serviceUuid],
        ),
      );
      _notifyCharacteristic = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(
          _service,
          'getCharacteristic',
          <dynamic>[config.notifyCharacteristicUuid],
        ),
      );
      _controlCharacteristic = await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(
          _service,
          'getCharacteristic',
          <dynamic>[config.controlCharacteristicUuid],
        ),
      );
      await js_util.promiseToFuture<dynamic>(
        js_util.callMethod(
          _notifyCharacteristic,
          'startNotifications',
          const <dynamic>[],
        ),
      );
      _notificationCallback ??= js_util.allowInterop((dynamic event) {
        _handleNotification(event);
      });
      js_util.callMethod(
        _notifyCharacteristic,
        'addEventListener',
        <dynamic>['characteristicvaluechanged', _notificationCallback],
      );
      _receiveBuffer.clear();
      _emitStatus(AdapterState.streaming, '蓝牙已自动重连: $_deviceId');
    } catch (error) {
      _emitStatus(AdapterState.disconnected, '蓝牙自动重连失败，请手动重连');
    }
  }

  dynamic _buildRequestOptions() {
    // Use the broad picker by default. ESP32/NimBLE devices are often visible
    // to phone Bluetooth settings while Chrome cannot match them through
    // strict name/service filters because the name or 128-bit UUID may only be
    // present in scan response data, or may differ in case after reflashing.
    final options = <String, dynamic>{
      'acceptAllDevices': true,
      'optionalServices': <String>[config.serviceUuid],
    };
    return js_util.jsify(options);
  }

  void _handleNotification(dynamic event) {
    final target = js_util.getProperty(event, 'target');
    final value = js_util.getProperty(target, 'value');
    final length = (js_util.getProperty(value, 'byteLength') as num?)?.toInt() ?? 0;
    final bytes = Uint8List(length);
    for (var index = 0; index < length; index++) {
      bytes[index] = (js_util.callMethod(value, 'getUint8', <dynamic>[index]) as num).toInt();
    }
    // Hard-cap the receive buffer to prevent unbounded growth on a noisy link.
    // BLE BIO1 frames are at most ~2 KiB; 64 KiB leaves room for 32+ queued frames.
    const maxReceiveBufferBytes = 65536;
    _receiveBuffer.addAll(bytes);
    if (_receiveBuffer.length > maxReceiveBufferBytes) {
      final overflow = _receiveBuffer.length - maxReceiveBufferBytes;
      // Retain the tail — the oldest bytes are the least useful.
      _receiveBuffer.removeRange(0, overflow);
    }
    _drainReceiveBuffer();
  }

  void _drainReceiveBuffer() {
    while (_receiveBuffer.isNotEmpty) {
      while (_receiveBuffer.isNotEmpty &&
          (_receiveBuffer.first == 0x0A || _receiveBuffer.first == 0x0D)) {
        _receiveBuffer.removeAt(0);
      }
      if (_receiveBuffer.isEmpty) {
        return;
      }
      if (_receiveBuffer.first == 0x7B) {
        if (!_tryConsumeJsonLine()) {
          return;
        }
        continue;
      }
      if (!_tryConsumeBinaryFrame()) {
        return;
      }
    }
  }

  bool _tryConsumeJsonLine() {
    final newlineIndex = _receiveBuffer.indexOf(0x0A);
    if (newlineIndex < 0) {
      return false;
    }
    final lineBytes = _receiveBuffer.sublist(0, newlineIndex);
    _receiveBuffer.removeRange(0, newlineIndex + 1);
    final line = utf8.decode(lineBytes, allowMalformed: true).trim();
    if (line.isNotEmpty) {
      _handleBleLine(line);
    }
    return true;
  }

  bool _tryConsumeBinaryFrame() {
    final magicIndex = _indexOfMagic(_receiveBuffer);
    if (magicIndex < 0) {
      if (_receiveBuffer.length > 3) {
        _receiveBuffer.removeRange(0, _receiveBuffer.length - 3);
      }
      return false;
    }
    if (magicIndex > 0) {
      _receiveBuffer.removeRange(0, magicIndex);
    }
    if (_receiveBuffer.length < 11) {
      return false;
    }

    final isBio2 = _receiveBuffer[3] == 0x32;
    final isBio3 = _receiveBuffer[3] == 0x33;
    final headerLength = isBio3 ? 20 : isBio2 ? 19 : 11;
    if (_receiveBuffer.length < headerLength) {
      return false;
    }

    if (isBio3) {
      final header = ByteData.sublistView(Uint8List.fromList(_receiveBuffer.sublist(0, headerLength)));
      final ecgCount = header.getUint16(10, Endian.little);
      final ppgCount = header.getUint16(12, Endian.little);
      final payloadLength = header.getUint16(14, Endian.little);
      final expectedPayloadLength = ecgCount * 12 + ppgCount * 16;
      final frameLength = headerLength + payloadLength;
      if (payloadLength != expectedPayloadLength) {
        _receiveBuffer.removeAt(0);
        return true;
      }
      if (_receiveBuffer.length < frameLength) {
        return false;
      }

      final frameBytes = Uint8List.fromList(_receiveBuffer.sublist(0, frameLength));
      _receiveBuffer.removeRange(0, frameLength);
      final batch = _Bio1BinaryCodec.decode(
        frameBytes,
        deviceId: _deviceId,
        sessionId: _sessionId,
        transport: 'ble_binary',
      );
      if (batch.isEmpty) {
        _emitStatus(AdapterState.error, 'BLE BIO frame parse failed');
      } else {
        _mergeCatalog(batch.channels);
        for (final frame in batch.frames) {
          _frameController.add(frame);
        }
      }
      return true;
    }

    final typeByte = _receiveBuffer[isBio2 ? 5 : 4];
    final sampleSize = _sampleSizeForType(typeByte);
    if (sampleSize == null) {
      _receiveBuffer.removeAt(0);
      return true;
    }

    final header = ByteData.sublistView(Uint8List.fromList(_receiveBuffer.sublist(0, headerLength)));
    final sampleCount = isBio2
        ? header.getUint16(11, Endian.little)
        : header.getUint16(9, Endian.little);
    final payloadLength = isBio2
        ? header.getUint16(13, Endian.little)
        : sampleCount * sampleSize;
    final frameLength = headerLength + payloadLength;
    if (payloadLength != sampleCount * sampleSize) {
      _receiveBuffer.removeAt(0);
      return true;
    }
    if (_receiveBuffer.length < frameLength) {
      return false;
    }

    final frameBytes = Uint8List.fromList(_receiveBuffer.sublist(0, frameLength));
    _receiveBuffer.removeRange(0, frameLength);
    if (isBio2) {
      final batch = _Bio1BinaryCodec.decode(
        frameBytes,
        deviceId: _deviceId,
        sessionId: _sessionId,
        transport: 'ble_binary',
      );
      if (batch.isEmpty) {
        _emitStatus(AdapterState.error, 'BLE BIO frame parse failed');
      } else {
        _mergeCatalog(batch.channels);
        for (final frame in batch.frames) {
          _frameController.add(frame);
        }
      }
    } else {
      _handleBinaryFrame(frameBytes);
    }
    return true;
  }

  void _handleBleLine(String line) {
    dynamic decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }

    final type = (decoded['type'] ?? '').toString();
    final payload = decoded['payload'];
    if (type == 'catalog' && payload is Map<String, dynamic>) {
      final rawChannels = (payload['channels'] as List<dynamic>? ?? const <dynamic>[]);
      _currentCatalog = rawChannels
          .map(
            (dynamic item) => ChannelDescriptor.fromJson(item as Map<String, dynamic>),
          )
          .toList();
      _catalogController.add(List<ChannelDescriptor>.from(_currentCatalog));
      _emitStatus(AdapterState.streaming, '蓝牙目录已同步，共 ${_currentCatalog.length} 个通道');
      return;
    }

    if (type == 'frame' && payload is Map<String, dynamic>) {
      _frameController.add(
        SignalFrame.fromJson(<String, dynamic>{
          ...payload,
          'transport': payload['transport'] ?? 'ble_json',
          'receivedAtMs': DateTime.now().millisecondsSinceEpoch,
          'sourceSeq': payload['sourceSeq'] ?? payload['seq'],
        }),
      );
      return;
    }

    if (type == 'status' && payload is Map<String, dynamic>) {
      final message = (payload['message'] ?? '蓝牙状态更新').toString();
      _emitStatus(AdapterState.streaming, message);
      return;
    }

    if (type == 'alerts' && payload is Map<String, dynamic>) {
      final message = (payload['message'] ?? '蓝牙报警').toString();
      _emitStatus(AdapterState.error, message);
      return;
    }

    if (decoded.containsKey('channelKey')) {
      _frameController.add(
        SignalFrame.fromJson(<String, dynamic>{
          ...decoded,
          'transport': decoded['transport'] ?? 'ble_json',
          'receivedAtMs': DateTime.now().millisecondsSinceEpoch,
          'sourceSeq': decoded['sourceSeq'] ?? decoded['seq'],
        }),
      );
    }
  }

  void _handleBinaryFrame(Uint8List frameBytes) {
    final data = ByteData.sublistView(frameBytes);
    final typeCode = String.fromCharCode(frameBytes[4]);
    final seq = data.getUint32(5, Endian.little);
    final sampleCount = data.getUint16(9, Endian.little);
    final sampleSize = _sampleSizeForType(frameBytes[4]);
    if (sampleSize == null || sampleCount == 0) {
      return;
    }

    switch (typeCode) {
      case 'E':
        _handleBinaryEcgFrame(data, seq, sampleCount, sampleSize);
        return;
      case 'P':
        _handleBinaryPpgFrame(data, seq, sampleCount, sampleSize);
        return;
      case 'I':
        _handleBinaryImuFrame(data, seq, sampleCount, sampleSize);
        return;
      case 'T':
        _handleBinaryTempFrame(data, seq, sampleCount, sampleSize);
        return;
      default:
        return;
    }
  }

  void _handleBinaryEcgFrame(
    ByteData data,
    int seq,
    int sampleCount,
    int sampleSize,
  ) {
    final timestampsUs = <int>[];
    final values = <double>[];
    var qualitySum = 0.0;
    for (var index = 0; index < sampleCount; index++) {
      final offset = 11 + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      values.add(data.getUint16(offset + 8, Endian.little).toDouble());
      final leadOff = sampleSize >= 12 &&
          (data.getUint8(offset + 10) != 0 || data.getUint8(offset + 11) != 0);
      qualitySum += leadOff ? 0.0 : 1.0;
    }

    final sampleRate = _estimateSampleRate(timestampsUs, 500);
    final quality = sampleCount == 0 ? 1.0 : qualitySum / sampleCount;
    _mergeCatalog(<ChannelDescriptor>[
      _buildChannelDescriptor(
        key: 'ecg',
        label: 'ECG',
        unit: 'adc',
        colorHex: '#F25F5C',
        sampleRate: sampleRate,
      ),
    ]);
    _emitSignalFrame(
      channelKey: 'ecg',
      seq: seq,
      unit: 'adc',
      sampleRate: sampleRate,
      timestampsUs: timestampsUs,
      samples: values,
      quality: quality,
    );
  }

  void _handleBinaryPpgFrame(
    ByteData data,
    int seq,
    int sampleCount,
    int sampleSize,
  ) {
    final timestampsUs = <int>[];
    final irValues = <double>[];
    final redValues = <double>[];
    for (var index = 0; index < sampleCount; index++) {
      final offset = 11 + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      irValues.add(data.getUint32(offset + 8, Endian.little).toDouble());
      redValues.add(data.getUint32(offset + 12, Endian.little).toDouble());
    }

    final sampleRate = _estimateSampleRate(timestampsUs, 200);
    _mergeCatalog(<ChannelDescriptor>[
      _buildChannelDescriptor(
        key: 'ppg_ir',
        label: 'PPG IR',
        unit: 'count',
        colorHex: '#247BA0',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'ppg_red',
        label: 'PPG RED',
        unit: 'count',
        colorHex: '#C84C5A',
        sampleRate: sampleRate,
      ),
    ]);
    _emitSignalFrame(
      channelKey: 'ppg_ir',
      seq: seq,
      unit: 'count',
      sampleRate: sampleRate,
      timestampsUs: timestampsUs,
      samples: irValues,
    );
    _emitSignalFrame(
      channelKey: 'ppg_red',
      seq: seq,
      unit: 'count',
      sampleRate: sampleRate,
      timestampsUs: timestampsUs,
      samples: redValues,
    );
  }

  void _handleBinaryImuFrame(
    ByteData data,
    int seq,
    int sampleCount,
    int sampleSize,
  ) {
    final timestampsUs = <int>[];
    final channelSamples = <String, List<double>>{
      'imu_ax': <double>[],
      'imu_ay': <double>[],
      'imu_az': <double>[],
      'imu_gx': <double>[],
      'imu_gy': <double>[],
      'imu_gz': <double>[],
    };
    for (var index = 0; index < sampleCount; index++) {
      final offset = 11 + index * sampleSize;
      timestampsUs.add(_readUint64Le(data, offset));
      channelSamples['imu_ax']!.add(data.getInt16(offset + 8, Endian.little).toDouble());
      channelSamples['imu_ay']!.add(data.getInt16(offset + 10, Endian.little).toDouble());
      channelSamples['imu_az']!.add(data.getInt16(offset + 12, Endian.little).toDouble());
      channelSamples['imu_gx']!.add(data.getInt16(offset + 14, Endian.little).toDouble());
      channelSamples['imu_gy']!.add(data.getInt16(offset + 16, Endian.little).toDouble());
      channelSamples['imu_gz']!.add(data.getInt16(offset + 18, Endian.little).toDouble());
    }

    final sampleRate = _estimateSampleRate(timestampsUs, 100);
    _mergeCatalog(<ChannelDescriptor>[
      _buildChannelDescriptor(
        key: 'imu_ax',
        label: 'IMU AX',
        unit: 'raw',
        colorHex: '#2A9D8F',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'imu_ay',
        label: 'IMU AY',
        unit: 'raw',
        colorHex: '#36B7A1',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'imu_az',
        label: 'IMU AZ',
        unit: 'raw',
        colorHex: '#55C7AE',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'imu_gx',
        label: 'IMU GX',
        unit: 'raw',
        colorHex: '#7B6DFF',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'imu_gy',
        label: 'IMU GY',
        unit: 'raw',
        colorHex: '#9A7CFF',
        sampleRate: sampleRate,
      ),
      _buildChannelDescriptor(
        key: 'imu_gz',
        label: 'IMU GZ',
        unit: 'raw',
        colorHex: '#B792FF',
        sampleRate: sampleRate,
      ),
    ]);
    for (final entry in channelSamples.entries) {
      _emitSignalFrame(
        channelKey: entry.key,
        seq: seq,
        unit: 'raw',
        sampleRate: sampleRate,
        timestampsUs: timestampsUs,
        samples: entry.value,
      );
    }
  }

  void _handleBinaryTempFrame(
    ByteData data,
    int seq,
    int sampleCount,
    int sampleSize,
  ) {
    final timestampsUs = <int>[];
    final values = <double>[];
    for (var index = 0; index < sampleCount; index++) {
      final offset = 11 + index * sampleSize;
      if (offset + sampleSize > data.lengthInBytes) break;
      timestampsUs.add(_readUint64Le(data, offset));
      values.add(data.getFloat32(offset + 10, Endian.little).toDouble());
    }
    if (timestampsUs.isEmpty) return;

    final sampleRate = _estimateSampleRate(timestampsUs, 1);
    _mergeCatalog(<ChannelDescriptor>[
      _buildChannelDescriptor(
        key: 'temp',
        label: '体温',
        unit: '°C',
        colorHex: '#E76F51',
        sampleRate: sampleRate,
      ),
    ]);
    _emitSignalFrame(
      channelKey: 'temp',
      seq: seq,
      unit: '°C',
      sampleRate: sampleRate,
      timestampsUs: timestampsUs,
      samples: values,
    );
  }

  void _emitSignalFrame({
    required String channelKey,
    required int seq,
    required String unit,
    required double sampleRate,
    required List<int> timestampsUs,
    required List<double> samples,
    double quality = 1.0,
  }) {
    final sampleTimestampsMs = timestampsUs
        .map((int timestampUs) => timestampUs ~/ 1000)
        .toList(growable: false);
    _frameController.add(
      SignalFrame(
        deviceId: _deviceId,
        sessionId: _sessionId,
        seq: seq,
        timestampMs: sampleTimestampsMs.first,
        channelKey: channelKey,
        sampleRate: sampleRate,
        unit: unit,
        quality: quality,
        samples: samples,
        sampleTimestampsMs: sampleTimestampsMs,
        transport: 'ble_binary',
        receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        sourceSeq: seq,
        frameVersion: 1,
        decodeStatus: 'ok',
      ),
    );
  }

  void _mergeCatalog(List<ChannelDescriptor> incoming) {
    var changed = false;
    final nextCatalog = List<ChannelDescriptor>.from(_currentCatalog);
    for (final descriptor in incoming) {
      final index = nextCatalog.indexWhere((ChannelDescriptor item) => item.key == descriptor.key);
      if (index < 0) {
        nextCatalog.add(descriptor);
        changed = true;
        continue;
      }
      final existing = nextCatalog[index];
      final updated = existing.copyWith(
        label: descriptor.label,
        unit: descriptor.unit,
        colorHex: descriptor.colorHex,
      );
      if (updated.label != existing.label ||
          updated.unit != existing.unit ||
          updated.colorHex != existing.colorHex) {
        nextCatalog[index] = updated;
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    _currentCatalog = nextCatalog;
    _catalogController.add(List<ChannelDescriptor>.from(_currentCatalog));
    _emitStatus(AdapterState.streaming, '已识别 ${_currentCatalog.length} 个蓝牙二进制通道');
  }

  ChannelDescriptor _buildChannelDescriptor({
    required String key,
    required String label,
    required String unit,
    required String colorHex,
    required double sampleRate,
  }) {
    final existingIndex =
        _currentCatalog.indexWhere((ChannelDescriptor item) => item.key == key);
    final existing = existingIndex >= 0 ? _currentCatalog[existingIndex] : null;
    return ChannelDescriptor(
      key: key,
      label: label,
      unit: unit,
      sampleRate: sampleRate,
      colorHex: colorHex,
      enabled: existing?.enabled ?? true,
    );
  }

  int? _sampleSizeForType(int typeByte) {
    switch (String.fromCharCode(typeByte)) {
      case 'E':
      case 'F':
        return 12;
      case 'P':
      case 'Q':
        return 16;
      case 'I':
        return 20;
      case 'T':
        return 15;
      default:
        return null;
    }
  }

  int _indexOfMagic(List<int> buffer) {
    for (var index = 0; index <= buffer.length - 4; index++) {
      if (buffer[index] == 0x42 &&
          buffer[index + 1] == 0x49 &&
          buffer[index + 2] == 0x4F &&
          (buffer[index + 3] == 0x31 ||
              buffer[index + 3] == 0x32 ||
              buffer[index + 3] == 0x33)) {
        return index;
      }
    }
    return -1;
  }

  int _readUint64Le(ByteData data, int offset) {
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    return high * 0x100000000 + low;
  }

  double _estimateSampleRate(List<int> timestampsUs, double fallback) {
    if (timestampsUs.length < 2) {
      return fallback;
    }
    var totalDelta = 0;
    var count = 0;
    for (var index = 1; index < timestampsUs.length; index++) {
      final delta = timestampsUs[index] - timestampsUs[index - 1];
      if (delta > 0) {
        totalDelta += delta;
        count++;
      }
    }
    if (count == 0 || totalDelta <= 0) {
      return fallback;
    }
    return 1000000.0 / (totalDelta / count);
  }

  @override
  Future<void> disconnect({bool silent = false}) async {
    _manualDisconnecting = true;
    try {
      if (_notifyCharacteristic != null && _notificationCallback != null) {
        js_util.callMethod(
          _notifyCharacteristic,
          'removeEventListener',
          <dynamic>['characteristicvaluechanged', _notificationCallback],
        );
        await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            _notifyCharacteristic,
            'stopNotifications',
            const <dynamic>[],
          ),
        );
      }
    } catch (_) {}

    try {
      if (_device != null && _disconnectCallback != null) {
        js_util.callMethod(
          _device,
          'removeEventListener',
          <dynamic>['gattserverdisconnected', _disconnectCallback],
        );
      }
    } catch (_) {}

    try {
      if (_server != null) {
        js_util.callMethod(_server, 'disconnect', const <dynamic>[]);
      }
    } catch (_) {
      try {
        final gatt = js_util.getProperty(_device, 'gatt');
        js_util.callMethod(gatt, 'disconnect', const <dynamic>[]);
      } catch (_) {}
    }

    _device = null;
    _server = null;
    _service = null;
    _notifyCharacteristic = null;
    _controlCharacteristic = null;
    _notificationCallback = null;
    _disconnectCallback = null;
    _receiveBuffer.clear();
    _currentCatalog = const <ChannelDescriptor>[];
    _deviceId = config.deviceNamePrefix;
    _sessionId = 'ble-session';
    _autoReconnectAttempts = 0;
    if (!silent) {
      _emitStatus(AdapterState.disconnected, '蓝牙连接已关闭');
    }
  }

  @override
  Future<void> updateChannels(List<ChannelDescriptor> channels) async {
    _currentCatalog = List<ChannelDescriptor>.from(channels);
    final enabledKeys = channels
        .where((ChannelDescriptor item) => item.enabled)
        .map((ChannelDescriptor item) => item.key)
        .toSet();
    enabledKeys.addAll(_statusTelemetryChannelKeys);
    await sendControl(
      ControlCommand(
        type: 'set_channels',
        payload: <String, dynamic>{
          'enabledKeys': enabledKeys.toList(),
        },
      ),
    );
  }

  @override
  Future<void> sendControl(ControlCommand command) async {
    final characteristic = _controlCharacteristic;
    if (characteristic == null) {
      return;
    }

    final bytes = Uint8List.fromList(utf8.encode('${jsonEncode(command.toJson())}\n'));
    try {
      if (js_util.hasProperty(characteristic, 'writeValueWithoutResponse')) {
        await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(
            characteristic,
            'writeValueWithoutResponse',
            <dynamic>[bytes],
          ),
        );
      } else {
        await js_util.promiseToFuture<dynamic>(
          js_util.callMethod(characteristic, 'writeValue', <dynamic>[bytes]),
        );
      }
    } catch (error) {
      _emitStatus(AdapterState.error, '蓝牙写入失败: $error');
      rethrow;
    }
  }

  void _emitStatus(AdapterState state, String message) {
    _statusController.add(
      AdapterStatus(
        state: state,
        message: message,
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _frameController.close();
    _statusController.close();
    _catalogController.close();
    _statsController.close();
  }
}

class _NormalizedChannel {
  const _NormalizedChannel({
    required this.key,
    required this.label,
    required this.unit,
  });

  final String key;
  final String label;
  final String unit;
}


