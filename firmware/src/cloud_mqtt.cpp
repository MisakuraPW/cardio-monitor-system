#include "cloud_mqtt.h"

#include <Arduino.h>
#include <WiFi.h>
#include <PubSubClient.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "data_logger.h"
#include "signal_dsp.h"

namespace {

WiFiClient g_wifiClient;
PubSubClient g_mqttClient(g_wifiClient);
QueueHandle_t g_ecgMqttQueue = nullptr;
QueueHandle_t g_ppgMqttQueue = nullptr;
QueueHandle_t g_imuMqttQueue = nullptr;

char g_clientId[48] = {};
uint32_t g_metricsSeq = 0;
uint32_t g_ecgSeq = 0;
uint32_t g_ppgSeq = 0;
uint32_t g_imuSeq = 0;
uint32_t g_lastWifiRetryMs = 0;
uint32_t g_lastMqttRetryMs = 0;
uint32_t g_lastDiagPublishMs = 0;
bool g_wifiConnectInProgress = false;
uint32_t g_wifiConnectStartMs = 0;
constexpr bool kDemoWifiMode = true;
constexpr bool kDemoPublishRawWaveforms = !kDemoWifiMode;
constexpr bool kDemoPublishFilteredWaveforms = true;
bool g_enableEcg = true;
bool g_enablePpg = true;
bool g_enableImu = !kDemoWifiMode;

uint32_t g_dropEcg = 0;
uint32_t g_dropPpg = 0;
uint32_t g_dropImu = 0;
uint32_t g_overwriteEcg = 0;
uint32_t g_overwritePpg = 0;
uint32_t g_overwriteImu = 0;
uint32_t g_wifiReconnectCount = 0;
uint32_t g_mqttPublishFailCount = 0;
uint32_t g_lastPublishLatencyMs = 0;
uint32_t g_ppgPressureDecimateCounter = 0;
uint32_t g_imuPressureDecimateCounter = 0;

constexpr uint32_t kEcgMqttQueueLen = 1024;
constexpr uint32_t kPpgMqttQueueLen = 256;
constexpr uint32_t kImuMqttQueueLen = 256;

constexpr size_t kEcgBatchMax = 40;
constexpr size_t kPpgBatchMax = 20;
constexpr size_t kImuBatchMax = 20;
constexpr TickType_t kMqttTaskPeriodTicks = pdMS_TO_TICKS(20);
constexpr uint8_t kPublishBurstsPerLoop = 2;
constexpr uint32_t kWifiConnectTimeoutMs = 20000;
constexpr uint16_t kEcgQueueHighPressurePermille = 850;
constexpr uint16_t kEcgQueueCriticalPressurePermille = 950;
constexpr uint16_t kPpgQueueHighPressurePermille = 850;
constexpr uint16_t kImuQueueHighPressurePermille = 800;

constexpr size_t kMqttPayloadBuffer = 1400;
constexpr bool kJsonPayloadEnabled = (MQTT_PAYLOAD_MODE == 0) || (MQTT_PAYLOAD_MODE == 2);
constexpr bool kBinaryPayloadEnabled = (MQTT_PAYLOAD_MODE == 1) || (MQTT_PAYLOAD_MODE == 2);

char g_sessionId[48] = {};
char g_topicStatus[96] = {};
char g_topicMetrics[96] = {};
char g_topicControl[96] = {};
char g_topicWaveEcg[96] = {};
char g_topicWavePpgIr[96] = {};
char g_topicWavePpgRed[96] = {};
char g_topicWaveImuAx[96] = {};
char g_topicWaveImuAy[96] = {};
char g_topicWaveImuAz[96] = {};
char g_topicWaveImuGx[96] = {};
char g_topicWaveImuGy[96] = {};
char g_topicWaveImuGz[96] = {};
char g_topicWaveBinEcg[96] = {};
char g_topicWaveBinPpg[96] = {};
char g_topicWaveBinImu[96] = {};
char g_topicWaveBinEcgFiltered[96] = {};
char g_topicWaveBinPpgFiltered[96] = {};

template <typename T>
bool enqueueDroppingOldest(QueueHandle_t queue, const T& sample, bool* overwrote) {
  if (queue == nullptr) {
    return false;
  }

  if (overwrote != nullptr) {
    *overwrote = false;
  }

  if (xQueueSend(queue, &sample, 0) == pdPASS) {
    return true;
  }

  T oldSample{};
  (void)xQueueReceive(queue, &oldSample, 0);
  const bool ok = (xQueueSend(queue, &sample, 0) == pdPASS);
  if (ok && overwrote != nullptr) {
    *overwrote = true;
  }
  return ok;
}

void appendU16Le(uint8_t* dst, const uint16_t v) {
  dst[0] = static_cast<uint8_t>(v & 0xFFU);
  dst[1] = static_cast<uint8_t>((v >> 8) & 0xFFU);
}

void appendU32Le(uint8_t* dst, const uint32_t v) {
  dst[0] = static_cast<uint8_t>(v & 0xFFU);
  dst[1] = static_cast<uint8_t>((v >> 8) & 0xFFU);
  dst[2] = static_cast<uint8_t>((v >> 16) & 0xFFU);
  dst[3] = static_cast<uint8_t>((v >> 24) & 0xFFU);
}

void appendU64Le(uint8_t* dst, const uint64_t v) {
  for (uint8_t i = 0; i < 8; ++i) {
    dst[i] = static_cast<uint8_t>((v >> (8U * i)) & 0xFFU);
  }
}

uint32_t crc32(const uint8_t* data, const size_t len) {
  uint32_t crc = 0xFFFFFFFFUL;
  for (size_t i = 0; i < len; ++i) {
    crc ^= data[i];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      const uint32_t mask = 0U - (crc & 1U);
      crc = (crc >> 1U) ^ (0xEDB88320UL & mask);
    }
  }
  return crc ^ 0xFFFFFFFFUL;
}

size_t beginBio2Frame(uint8_t* payload,
                      const size_t capacity,
                      const char type,
                      const uint32_t seq,
                      const uint16_t sampleCount,
                      const uint16_t payloadLen) {
  if (payload == nullptr || capacity < 19U) {
    return 0;
  }
  size_t off = 0;
  payload[off++] = 'B';
  payload[off++] = 'I';
  payload[off++] = 'O';
  payload[off++] = '2';
  payload[off++] = 1;  // BIO2 header version
  payload[off++] = static_cast<uint8_t>(type);
  payload[off++] = 0;  // flags
  appendU32Le(&payload[off], seq);
  off += 4;
  appendU16Le(&payload[off], sampleCount);
  off += 2;
  appendU16Le(&payload[off], payloadLen);
  off += 2;
  appendU32Le(&payload[off], 0);
  off += 4;
  return off;
}

void finishBio2Frame(uint8_t* payload, const size_t payloadOffset, const size_t payloadLen) {
  appendU32Le(&payload[15], crc32(payload + payloadOffset, payloadLen));
}

uint16_t queueFillPermille(QueueHandle_t queue, const uint32_t queueLen) {
  if (queue == nullptr || queueLen == 0) {
    return 0;
  }
  const uint32_t waiting = static_cast<uint32_t>(uxQueueMessagesWaiting(queue));
  return static_cast<uint16_t>((waiting * 1000U) / queueLen);
}

bool publishTextTracked(const char* topic, const char* payload, bool retained) {
  if (topic == nullptr || payload == nullptr) {
    return false;
  }

  const uint32_t t0 = millis();
  const bool ok = g_mqttClient.publish(topic, payload, retained);
  g_lastPublishLatencyMs = millis() - t0;
  if (!ok) {
    ++g_mqttPublishFailCount;
  }
  return ok;
}

bool publishBinaryTracked(const char* topic, const uint8_t* payload, const size_t len, bool retained) {
  if (topic == nullptr || payload == nullptr || len == 0) {
    return false;
  }

  const uint32_t t0 = millis();
  const bool ok = g_mqttClient.publish(topic, payload, len, retained);
  g_lastPublishLatencyMs = millis() - t0;
  if (!ok) {
    ++g_mqttPublishFailCount;
  }
  return ok;
}

template <typename T>
size_t dequeueBatch(QueueHandle_t queue, T* batch, const size_t batchMax) {
  if (queue == nullptr || batch == nullptr || batchMax == 0) {
    return 0;
  }

  size_t n = 0;
  while (n < batchMax && xQueueReceive(queue, &batch[n], 0) == pdPASS) {
    ++n;
  }
  return n;
}

void buildClientId() {
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(g_clientId, sizeof(g_clientId), "%s-%04X", MQTT_CLIENT_ID_PREFIX,
           static_cast<unsigned>(chipId & 0xFFFFU));
  snprintf(g_sessionId, sizeof(g_sessionId), "%s-%04X", MQTT_SESSION_ID,
           static_cast<unsigned>(chipId & 0xFFFFU));
}

void buildTopics() {
  snprintf(g_topicStatus, sizeof(g_topicStatus), "%s/%s/status", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicMetrics, sizeof(g_topicMetrics), "%s/%s/metrics", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicControl, sizeof(g_topicControl), "%s/%s/control", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveEcg, sizeof(g_topicWaveEcg), "%s/%s/waveform/ecg", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWavePpgIr, sizeof(g_topicWavePpgIr), "%s/%s/waveform/ppg_ir", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWavePpgRed, sizeof(g_topicWavePpgRed), "%s/%s/waveform/ppg_red", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuAx, sizeof(g_topicWaveImuAx), "%s/%s/waveform/imu_ax", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuAy, sizeof(g_topicWaveImuAy), "%s/%s/waveform/imu_ay", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuAz, sizeof(g_topicWaveImuAz), "%s/%s/waveform/imu_az", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuGx, sizeof(g_topicWaveImuGx), "%s/%s/waveform/imu_gx", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuGy, sizeof(g_topicWaveImuGy), "%s/%s/waveform/imu_gy", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveImuGz, sizeof(g_topicWaveImuGz), "%s/%s/waveform/imu_gz", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinEcg, sizeof(g_topicWaveBinEcg), "%s/%s/waveform_bin/ecg", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinPpg, sizeof(g_topicWaveBinPpg), "%s/%s/waveform_bin/ppg", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinImu, sizeof(g_topicWaveBinImu), "%s/%s/waveform_bin/imu", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinEcgFiltered, sizeof(g_topicWaveBinEcgFiltered), "%s/%s/waveform_bin/ecg_filtered", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinPpgFiltered, sizeof(g_topicWaveBinPpgFiltered), "%s/%s/waveform_bin/ppg_filtered", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
}

bool textContains(const char* text, const char* needle) {
  return text != nullptr && needle != nullptr && strstr(text, needle) != nullptr;
}

bool extractFloatValue(const char* text, const char* key, float* out) {
  if (text == nullptr || key == nullptr || out == nullptr) {
    return false;
  }
  const char* pos = strstr(text, key);
  if (pos == nullptr) {
    return false;
  }
  pos = strchr(pos, ':');
  if (pos == nullptr) {
    return false;
  }
  *out = static_cast<float>(atof(pos + 1));
  return true;
}

bool extractBoolValue(const char* text, const char* key, bool* out) {
  if (text == nullptr || key == nullptr || out == nullptr) {
    return false;
  }
  const char* pos = strstr(text, key);
  if (pos == nullptr) {
    return false;
  }
  pos = strchr(pos, ':');
  if (pos == nullptr) {
    return false;
  }
  while (*(++pos) == ' ' || *pos == '"') {}
  if (strncmp(pos, "true", 4) == 0 || *pos == '1') {
    *out = true;
    return true;
  }
  if (strncmp(pos, "false", 5) == 0 || *pos == '0') {
    *out = false;
    return true;
  }
  return false;
}

void publishDiagTelemetry();

void resetCounters() {
  g_dropEcg = 0;
  g_dropPpg = 0;
  g_dropImu = 0;
  g_overwriteEcg = 0;
  g_overwritePpg = 0;
  g_overwriteImu = 0;
  g_mqttPublishFailCount = 0;
  g_wifiReconnectCount = 0;
  g_ppgPressureDecimateCounter = 0;
  g_imuPressureDecimateCounter = 0;
}

void handleControlPayload(const char* payload) {
  if (payload == nullptr) {
    return;
  }
  if (textContains(payload, "reset_counters")) {
    resetCounters();
    data_logger::logStatus("[NET] MQTT control reset_counters.");
    return;
  }
  if (textContains(payload, "set_channels")) {
    g_enableEcg = textContains(payload, "\"ecg\"") ||
                  textContains(payload, "\"ecg_filtered\"");
    g_enablePpg = textContains(payload, "\"ppg\"") ||
                  textContains(payload, "\"ppg_ir\"") ||
                  textContains(payload, "\"ppg_red\"") ||
                  textContains(payload, "\"ppg_ir_filtered\"") ||
                  textContains(payload, "\"ppg_red_filtered\"");
    g_enableImu = !kDemoWifiMode &&
                  (textContains(payload, "\"imu\"") ||
                   textContains(payload, "\"imu_ax\"") ||
                   textContains(payload, "\"imu_gx\""));
    data_logger::logStatus("[NET] MQTT control set_channels.");
    return;
  }
  if (textContains(payload, "ping")) {
    publishDiagTelemetry();
    return;
  }
  if (textContains(payload, "reset_dsp_state")) {
    signal_dsp::reset();
    data_logger::logStatus("[NET] DSP state reset.");
    return;
  }
  if (textContains(payload, "set_dsp_enabled")) {
    signal_dsp::setEnabled(textContains(payload, "true") || textContains(payload, "\"enabled\":1"));
    data_logger::logStatus("[NET] DSP enabled updated.");
    return;
  }
  if (textContains(payload, "set_dsp_params")) {
    signal_dsp::DspParams params = signal_dsp::params();
    bool boolValue = false;
    float value = 0.0f;
    if (extractBoolValue(payload, "enabled", &boolValue)) params.enabled = boolValue;
    if (extractBoolValue(payload, "ecgNotchEnabled", &boolValue)) params.ecgNotchEnabled = boolValue;
    if (extractBoolValue(payload, "ppgNlmsEnabled", &boolValue)) params.ppgNlmsEnabled = boolValue;
    if (extractFloatValue(payload, "ecgHighpassHz", &value)) params.ecgHighpassHz = value;
    if (extractFloatValue(payload, "ecgLowpassHz", &value)) params.ecgLowpassHz = value;
    if (extractFloatValue(payload, "ecgNotchHz", &value)) params.ecgNotchHz = value;
    if (extractFloatValue(payload, "ecgNotchQ", &value)) params.ecgNotchQ = value;
    if (extractFloatValue(payload, "ecgPeakThreshold", &value)) params.ecgPeakThreshold = value;
    if (extractFloatValue(payload, "ppgHighpassHz", &value)) params.ppgHighpassHz = value;
    if (extractFloatValue(payload, "ppgLowpassHz", &value)) params.ppgLowpassHz = value;
    if (extractFloatValue(payload, "nlmsTaps", &value)) params.nlmsTaps = static_cast<uint8_t>(value);
    if (extractFloatValue(payload, "nlmsStep", &value)) params.nlmsStep = value;
    if (extractFloatValue(payload, "nlmsEpsilon", &value)) params.nlmsEpsilon = value;
    if (extractFloatValue(payload, "motionThreshold", &value)) params.motionThreshold = value;
    signal_dsp::updateParams(params);
    data_logger::logStatus("[NET] DSP params updated.");
    return;
  }
  if (textContains(payload, "set_payload_mode") || textContains(payload, "set_sample_rates")) {
    data_logger::logStatus("[NET] MQTT control accepted for host-side diagnostics.");
  }
}

void onMqttMessage(char* topic, uint8_t* payload, unsigned int length) {
  if (topic == nullptr || strcmp(topic, g_topicControl) != 0) {
    return;
  }
  char buffer[256];
  const unsigned int limit = static_cast<unsigned int>(sizeof(buffer) - 1U);
  const unsigned int copyLen = length < limit ? length : limit;
  memcpy(buffer, payload, copyLen);
  buffer[copyLen] = '\0';
  handleControlPayload(buffer);
}

uint64_t tsUsToMs(const uint64_t tsUs) {
  return tsUs / 1000ULL;
}

bool publishWaveformU16(const char* topic,
                        const uint16_t* values,
                        const size_t n,
                        const uint32_t seq,
                        const uint64_t timestampMs,
                        const uint32_t sampleRate,
                        const char* unit) {
  if (topic == nullptr || values == nullptr || n == 0) {
    return false;
  }

  char payload[kMqttPayloadBuffer];
  int w = snprintf(payload, sizeof(payload),
                   "{\"deviceId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%llu,\"sampleRate\":%lu,\"unit\":\"%s\",\"quality\":1.0,\"samples\":[",
                   MQTT_TOPIC_DEVICE_ID,
                   g_sessionId,
                   static_cast<unsigned long>(seq),
                   static_cast<unsigned long long>(timestampMs),
                   static_cast<unsigned long>(sampleRate),
                   unit);
  if (w <= 0 || static_cast<size_t>(w) >= sizeof(payload)) {
    return false;
  }

  size_t off = static_cast<size_t>(w);
  for (size_t i = 0; i < n; ++i) {
    w = snprintf(payload + off, sizeof(payload) - off,
                 "%s%u",
                 (i == 0) ? "" : ",",
                 static_cast<unsigned>(values[i]));
    if (w <= 0 || static_cast<size_t>(w) >= (sizeof(payload) - off)) {
      return false;
    }
    off += static_cast<size_t>(w);
  }

  if (off + 3 >= sizeof(payload)) {
    return false;
  }
  payload[off++] = ']';
  payload[off++] = '}';
  payload[off] = '\0';
  return publishTextTracked(topic, payload, false);
}

bool publishWaveformU32(const char* topic,
                        const uint32_t* values,
                        const size_t n,
                        const uint32_t seq,
                        const uint64_t timestampMs,
                        const uint32_t sampleRate,
                        const char* unit) {
  if (topic == nullptr || values == nullptr || n == 0) {
    return false;
  }

  char payload[kMqttPayloadBuffer];
  int w = snprintf(payload, sizeof(payload),
                   "{\"deviceId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%llu,\"sampleRate\":%lu,\"unit\":\"%s\",\"quality\":1.0,\"samples\":[",
                   MQTT_TOPIC_DEVICE_ID,
                   g_sessionId,
                   static_cast<unsigned long>(seq),
                   static_cast<unsigned long long>(timestampMs),
                   static_cast<unsigned long>(sampleRate),
                   unit);
  if (w <= 0 || static_cast<size_t>(w) >= sizeof(payload)) {
    return false;
  }

  size_t off = static_cast<size_t>(w);
  for (size_t i = 0; i < n; ++i) {
    w = snprintf(payload + off, sizeof(payload) - off,
                 "%s%lu",
                 (i == 0) ? "" : ",",
                 static_cast<unsigned long>(values[i]));
    if (w <= 0 || static_cast<size_t>(w) >= (sizeof(payload) - off)) {
      return false;
    }
    off += static_cast<size_t>(w);
  }

  if (off + 3 >= sizeof(payload)) {
    return false;
  }
  payload[off++] = ']';
  payload[off++] = '}';
  payload[off] = '\0';
  return publishTextTracked(topic, payload, false);
}

bool publishWaveformI16(const char* topic,
                        const int16_t* values,
                        const size_t n,
                        const uint32_t seq,
                        const uint64_t timestampMs,
                        const uint32_t sampleRate,
                        const char* unit) {
  if (topic == nullptr || values == nullptr || n == 0) {
    return false;
  }

  char payload[kMqttPayloadBuffer];
  int w = snprintf(payload, sizeof(payload),
                   "{\"deviceId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%llu,\"sampleRate\":%lu,\"unit\":\"%s\",\"quality\":1.0,\"samples\":[",
                   MQTT_TOPIC_DEVICE_ID,
                   g_sessionId,
                   static_cast<unsigned long>(seq),
                   static_cast<unsigned long long>(timestampMs),
                   static_cast<unsigned long>(sampleRate),
                   unit);
  if (w <= 0 || static_cast<size_t>(w) >= sizeof(payload)) {
    return false;
  }

  size_t off = static_cast<size_t>(w);
  for (size_t i = 0; i < n; ++i) {
    w = snprintf(payload + off, sizeof(payload) - off,
                 "%s%d",
                 (i == 0) ? "" : ",",
                 static_cast<int>(values[i]));
    if (w <= 0 || static_cast<size_t>(w) >= (sizeof(payload) - off)) {
      return false;
    }
    off += static_cast<size_t>(w);
  }

  if (off + 3 >= sizeof(payload)) {
    return false;
  }
  payload[off++] = ']';
  payload[off++] = '}';
  payload[off] = '\0';
  return publishTextTracked(topic, payload, false);
}

bool ensureWifiConnected() {
  const wl_status_t status = WiFi.status();
  if (status == WL_CONNECTED) {
    g_wifiConnectInProgress = false;
    return true;
  }

  const uint32_t nowMs = millis();

  // Do not restart WiFi.begin while association/authentication is in progress.
  // Reissuing begin too often can reset the join flow and prevent connection.
  if (g_wifiConnectInProgress) {
    if ((nowMs - g_wifiConnectStartMs) < kWifiConnectTimeoutMs) {
      return false;
    }

    // Timed out: clear stale state then allow a clean retry.
    g_wifiConnectInProgress = false;
    WiFi.disconnect(false, true);
  }

  if ((nowMs - g_lastWifiRetryMs) < WIFI_RETRY_INTERVAL_MS) {
    return false;
  }
  g_lastWifiRetryMs = nowMs;

  data_logger::logStatus("[NET] Connecting WiFi...");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  ++g_wifiReconnectCount;
  g_wifiConnectInProgress = true;
  g_wifiConnectStartMs = nowMs;

  // Keep reconnect non-blocking; MQTT task should keep scheduling regularly.
  return false;
}

bool ensureMqttConnected() {
  if (g_mqttClient.connected()) {
    return true;
  }

  const uint32_t nowMs = millis();
  if ((nowMs - g_lastMqttRetryMs) < MQTT_RETRY_INTERVAL_MS) {
    return false;
  }
  g_lastMqttRetryMs = nowMs;

  data_logger::logStatus("[NET] Connecting MQTT...");
  const bool ok = g_mqttClient.connect(g_clientId);
  if (!ok) {
    char msg[96];
    snprintf(msg, sizeof(msg), "[NET] MQTT connect failed, rc=%d", g_mqttClient.state());
    data_logger::logStatus(msg);
    return false;
  }

  char onlinePayload[128];
  snprintf(onlinePayload, sizeof(onlinePayload),
           "{\"deviceId\":\"%s\",\"clientId\":\"%s\",\"sessionId\":\"%s\",\"status\":\"online\",\"timestampMs\":%lu}",
           MQTT_TOPIC_DEVICE_ID,
           g_clientId,
           g_sessionId,
           static_cast<unsigned long>(millis()));
  (void)publishTextTracked(g_topicStatus, onlinePayload, true);
  (void)g_mqttClient.subscribe(g_topicControl, 1);
  data_logger::logStatus("[NET] MQTT connected.");
  return true;
}

void publishDiagTelemetry() {
  const uint32_t nowMs = millis();
  if ((nowMs - g_lastDiagPublishMs) < MQTT_PUBLISH_PERIOD_MS) {
    return;
  }
  g_lastDiagPublishMs = nowMs;

  const uint32_t qEcg = (g_ecgMqttQueue == nullptr) ? 0 : static_cast<uint32_t>(uxQueueMessagesWaiting(g_ecgMqttQueue));
  const uint32_t qPpg = (g_ppgMqttQueue == nullptr) ? 0 : static_cast<uint32_t>(uxQueueMessagesWaiting(g_ppgMqttQueue));
  const uint32_t qImu = (g_imuMqttQueue == nullptr) ? 0 : static_cast<uint32_t>(uxQueueMessagesWaiting(g_imuMqttQueue));
  const signal_dsp::DspMetrics dsp = signal_dsp::metrics();

  char payload[kMqttPayloadBuffer];
  snprintf(payload, sizeof(payload),
           "{\"deviceId\":\"%s\",\"clientId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%lu,"
           "\"ecgQueueLen\":%lu,\"ppgQueueLen\":%lu,\"imuQueueLen\":%lu,"
           "\"ecgDropCount\":%lu,\"ppgDropCount\":%lu,\"imuDropCount\":%lu,"
           "\"mqttPublishFailCount\":%lu,\"wifiReconnectCount\":%lu,"
           "\"rssi\":%ld,\"heapFree\":%lu,\"lastPublishLatencyMs\":%lu,"
           "\"dsp\":{\"enabled\":%s,\"version\":%lu,\"motion\":%.3f,\"ecgQuality\":%.3f,\"ppgQuality\":%.3f,\"ecgBpm\":%.2f,\"ppgBpm\":%.2f},"
           "\"ow\":{\"ecg\":%lu,\"ppg\":%lu,\"imu\":%lu}}",
           MQTT_TOPIC_DEVICE_ID,
           g_clientId,
           g_sessionId,
           static_cast<unsigned long>(g_metricsSeq++),
           static_cast<unsigned long>(nowMs),
           static_cast<unsigned long>(qEcg),
           static_cast<unsigned long>(qPpg),
           static_cast<unsigned long>(qImu),
           static_cast<unsigned long>(g_dropEcg),
           static_cast<unsigned long>(g_dropPpg),
           static_cast<unsigned long>(g_dropImu),
           static_cast<unsigned long>(g_mqttPublishFailCount),
           static_cast<unsigned long>(g_wifiReconnectCount),
           static_cast<long>(WiFi.RSSI()),
           static_cast<unsigned long>(ESP.getFreeHeap()),
           static_cast<unsigned long>(g_lastPublishLatencyMs),
           dsp.enabled ? "true" : "false",
           static_cast<unsigned long>(dsp.paramsVersion),
           static_cast<double>(dsp.motionLevel),
           static_cast<double>(dsp.ecgQuality),
           static_cast<double>(dsp.ppgQuality),
           static_cast<double>(dsp.ecgHeartRateBpm),
           static_cast<double>(dsp.ppgPulseRateBpm),
           static_cast<unsigned long>(g_overwriteEcg),
           static_cast<unsigned long>(g_overwritePpg),
           static_cast<unsigned long>(g_overwriteImu));

  (void)publishTextTracked(g_topicMetrics, payload, false);
}

void publishEcgSamples() {
  if (g_ecgMqttQueue == nullptr) {
    return;
  }

  EcgSample batch[kEcgBatchMax];
  const size_t n = dequeueBatch(g_ecgMqttQueue, batch, kEcgBatchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_ecgSeq++;

  if (kJsonPayloadEnabled && kDemoPublishRawWaveforms) {
    uint16_t values[kEcgBatchMax] = {};
    for (size_t i = 0; i < n; ++i) {
      values[i] = batch[i].raw_adc;
    }

    if (!publishWaveformU16(g_topicWaveEcg,
                            values,
                            n,
                            seq,
                            tsUsToMs(batch[0].ts_us),
                            ECG_SAMPLE_RATE_HZ,
                            "adc")) {
      data_logger::logStatus("[NET] MQTT ECG waveform publish failed.");
    }
  }

  if (kBinaryPayloadEnabled && kDemoPublishRawWaveforms) {
    uint8_t payload[kMqttPayloadBuffer] = {};
    const uint16_t payloadLen = static_cast<uint16_t>(n * 12U);
    const size_t payloadOffset = beginBio2Frame(payload, sizeof(payload), 'E', seq, static_cast<uint16_t>(n), payloadLen);
    size_t off = payloadOffset;

    for (size_t i = 0; i < n; ++i) {
      if (off + 12 > sizeof(payload)) {
        break;
      }
      appendU64Le(&payload[off], batch[i].ts_us);
      off += 8;
      appendU16Le(&payload[off], batch[i].raw_adc);
      off += 2;
      payload[off++] = static_cast<uint8_t>(batch[i].lead_off_plus ? 1 : 0);
      payload[off++] = static_cast<uint8_t>(batch[i].lead_off_minus ? 1 : 0);
    }
    finishBio2Frame(payload, payloadOffset, off - payloadOffset);

    if (!publishBinaryTracked(g_topicWaveBinEcg, payload, off, false)) {
      data_logger::logStatus("[NET] MQTT ECG BIN publish failed.");
    }

  }

  if (kBinaryPayloadEnabled && kDemoPublishFilteredWaveforms) {
    uint8_t filteredPayload[kMqttPayloadBuffer] = {};
    const uint16_t filteredPayloadLen = static_cast<uint16_t>(n * 12U);
    const size_t filteredOffset = beginBio2Frame(filteredPayload, sizeof(filteredPayload), 'F', seq, static_cast<uint16_t>(n), filteredPayloadLen);
    size_t filteredOff = filteredOffset;
    for (size_t i = 0; i < n; ++i) {
      if (filteredOff + 12 > sizeof(filteredPayload)) {
        break;
      }
      appendU64Le(&filteredPayload[filteredOff], batch[i].ts_us);
      filteredOff += 8;
      appendU16Le(&filteredPayload[filteredOff], batch[i].filtered_adc);
      filteredOff += 2;
      filteredPayload[filteredOff++] = batch[i].flags;
      filteredPayload[filteredOff++] = static_cast<uint8_t>(constrain(batch[i].quality * 100.0f, 0.0f, 100.0f));
    }
    finishBio2Frame(filteredPayload, filteredOffset, filteredOff - filteredOffset);
    if (!publishBinaryTracked(g_topicWaveBinEcgFiltered, filteredPayload, filteredOff, false)) {
      data_logger::logStatus("[NET] MQTT ECG filtered BIN publish failed.");
    }
  }
}

void publishPpgSamples() {
  if (g_ppgMqttQueue == nullptr) {
    return;
  }

  PpgSample batch[kPpgBatchMax];
  const size_t n = dequeueBatch(g_ppgMqttQueue, batch, kPpgBatchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_ppgSeq++;

  if (kJsonPayloadEnabled && kDemoPublishRawWaveforms) {
    uint32_t valuesIr[kPpgBatchMax] = {};
    uint32_t valuesRed[kPpgBatchMax] = {};
    for (size_t i = 0; i < n; ++i) {
      valuesIr[i] = batch[i].ir;
      valuesRed[i] = batch[i].red;
    }

    const uint64_t tsMs = tsUsToMs(batch[0].ts_us);
    const bool okIr = publishWaveformU32(g_topicWavePpgIr,
                                         valuesIr,
                                         n,
                                         seq,
                                         tsMs,
                                         PPG_SAMPLE_RATE_HZ,
                                         "count");
    const bool okRed = publishWaveformU32(g_topicWavePpgRed,
                                          valuesRed,
                                          n,
                                          seq,
                                          tsMs,
                                          PPG_SAMPLE_RATE_HZ,
                                          "count");
    if (!okIr || !okRed) {
      data_logger::logStatus("[NET] MQTT PPG waveform publish failed.");
    }
  }

  if (kBinaryPayloadEnabled && kDemoPublishRawWaveforms) {
    uint8_t payload[kMqttPayloadBuffer] = {};
    const uint16_t payloadLen = static_cast<uint16_t>(n * 16U);
    const size_t payloadOffset = beginBio2Frame(payload, sizeof(payload), 'P', seq, static_cast<uint16_t>(n), payloadLen);
    size_t off = payloadOffset;

    for (size_t i = 0; i < n; ++i) {
      if (off + 16 > sizeof(payload)) {
        break;
      }
      appendU64Le(&payload[off], batch[i].ts_us);
      off += 8;
      appendU32Le(&payload[off], batch[i].ir);
      off += 4;
      appendU32Le(&payload[off], batch[i].red);
      off += 4;
    }
    finishBio2Frame(payload, payloadOffset, off - payloadOffset);

    if (!publishBinaryTracked(g_topicWaveBinPpg, payload, off, false)) {
      data_logger::logStatus("[NET] MQTT PPG BIN publish failed.");
    }

  }

  if (kBinaryPayloadEnabled && kDemoPublishFilteredWaveforms) {
    uint8_t filteredPayload[kMqttPayloadBuffer] = {};
    const uint16_t filteredPayloadLen = static_cast<uint16_t>(n * 16U);
    const size_t filteredOffset = beginBio2Frame(filteredPayload, sizeof(filteredPayload), 'Q', seq, static_cast<uint16_t>(n), filteredPayloadLen);
    size_t filteredOff = filteredOffset;
    for (size_t i = 0; i < n; ++i) {
      if (filteredOff + 16 > sizeof(filteredPayload)) {
        break;
      }
      appendU64Le(&filteredPayload[filteredOff], batch[i].ts_us);
      filteredOff += 8;
      appendU32Le(&filteredPayload[filteredOff], batch[i].filtered_ir);
      filteredOff += 4;
      appendU32Le(&filteredPayload[filteredOff], batch[i].filtered_red);
      filteredOff += 4;
    }
    finishBio2Frame(filteredPayload, filteredOffset, filteredOff - filteredOffset);
    if (!publishBinaryTracked(g_topicWaveBinPpgFiltered, filteredPayload, filteredOff, false)) {
      data_logger::logStatus("[NET] MQTT PPG filtered BIN publish failed.");
    }
  }
}

void publishImuSamples() {
  if (kDemoWifiMode) {
    return;
  }
  if (g_imuMqttQueue == nullptr) {
    return;
  }

  ImuSample batch[kImuBatchMax];
  const size_t n = dequeueBatch(g_imuMqttQueue, batch, kImuBatchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_imuSeq++;

  if (kJsonPayloadEnabled) {
    int16_t valuesAx[kImuBatchMax] = {};
    int16_t valuesAy[kImuBatchMax] = {};
    int16_t valuesAz[kImuBatchMax] = {};
    int16_t valuesGx[kImuBatchMax] = {};
    int16_t valuesGy[kImuBatchMax] = {};
    int16_t valuesGz[kImuBatchMax] = {};

    for (size_t i = 0; i < n; ++i) {
      valuesAx[i] = batch[i].acc_x;
      valuesAy[i] = batch[i].acc_y;
      valuesAz[i] = batch[i].acc_z;
      valuesGx[i] = batch[i].gyr_x;
      valuesGy[i] = batch[i].gyr_y;
      valuesGz[i] = batch[i].gyr_z;
    }

    const uint64_t tsMs = tsUsToMs(batch[0].ts_us);
    const bool okAx = publishWaveformI16(g_topicWaveImuAx, valuesAx, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    const bool okAy = publishWaveformI16(g_topicWaveImuAy, valuesAy, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    const bool okAz = publishWaveformI16(g_topicWaveImuAz, valuesAz, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    const bool okGx = publishWaveformI16(g_topicWaveImuGx, valuesGx, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    const bool okGy = publishWaveformI16(g_topicWaveImuGy, valuesGy, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    const bool okGz = publishWaveformI16(g_topicWaveImuGz, valuesGz, n, seq, tsMs, BMI_SAMPLE_RATE_HZ, "LSB");
    if (!okAx || !okAy || !okAz || !okGx || !okGy || !okGz) {
      data_logger::logStatus("[NET] MQTT IMU waveform publish failed.");
    }
  }

  if (kBinaryPayloadEnabled) {
    uint8_t payload[kMqttPayloadBuffer] = {};
    const uint16_t payloadLen = static_cast<uint16_t>(n * 20U);
    const size_t payloadOffset = beginBio2Frame(payload, sizeof(payload), 'I', seq, static_cast<uint16_t>(n), payloadLen);
    size_t off = payloadOffset;

    for (size_t i = 0; i < n; ++i) {
      if (off + 20 > sizeof(payload)) {
        break;
      }
      appendU64Le(&payload[off], batch[i].ts_us);
      off += 8;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].acc_x));
      off += 2;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].acc_y));
      off += 2;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].acc_z));
      off += 2;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].gyr_x));
      off += 2;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].gyr_y));
      off += 2;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].gyr_z));
      off += 2;
    }
    finishBio2Frame(payload, payloadOffset, off - payloadOffset);

    if (!publishBinaryTracked(g_topicWaveBinImu, payload, off, false)) {
      data_logger::logStatus("[NET] MQTT IMU BIN publish failed.");
    }
  }
}

}  // namespace

namespace cloud_mqtt {

void begin() {
  buildClientId();
  buildTopics();

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setSleep(WIFI_PS_NONE);

  // Trigger the first association attempt during init so WiFi does not depend
  // on mqttTask startup timing.
  WiFi.disconnect(false, true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  g_wifiConnectInProgress = true;
  g_wifiConnectStartMs = millis();
  g_lastWifiRetryMs = g_wifiConnectStartMs;

  if (g_ecgMqttQueue == nullptr) {
    g_ecgMqttQueue = xQueueCreate(kEcgMqttQueueLen, sizeof(EcgSample));
    if (g_ecgMqttQueue == nullptr) {
      data_logger::logStatus("[NET] ECG MQTT queue create failed.");
    }
  }

  if (g_ppgMqttQueue == nullptr) {
    g_ppgMqttQueue = xQueueCreate(kPpgMqttQueueLen, sizeof(PpgSample));
    if (g_ppgMqttQueue == nullptr) {
      data_logger::logStatus("[NET] PPG MQTT queue create failed.");
    }
  }

  if (g_imuMqttQueue == nullptr) {
    g_imuMqttQueue = xQueueCreate(kImuMqttQueueLen, sizeof(ImuSample));
    if (g_imuMqttQueue == nullptr) {
      data_logger::logStatus("[NET] IMU MQTT queue create failed.");
    }
  }

  g_mqttClient.setServer(MQTT_BROKER_HOST, MQTT_BROKER_PORT);
  g_mqttClient.setBufferSize(kMqttPayloadBuffer + 64);
  g_mqttClient.setKeepAlive(30);
  g_mqttClient.setCallback(onMqttMessage);

  char msg[128];
  snprintf(msg, sizeof(msg), "[NET] MQTT init host=%s:%d id=%s ecgBin=%s",
           MQTT_BROKER_HOST, MQTT_BROKER_PORT, g_clientId, g_topicWaveBinEcg);
  data_logger::logStatus(msg);
}

bool enqueueEcg(const EcgSample& sample) {
  if (!g_enableEcg) {
    return true;
  }
  if (g_ecgMqttQueue == nullptr) {
    return false;
  }
  bool overwrote = false;
  if (enqueueDroppingOldest(g_ecgMqttQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwriteEcg;
      ++g_dropEcg;
    }
    return true;
  }
  ++g_dropEcg;
  return false;
}

bool enqueuePpg(const PpgSample& sample) {
  if (!g_enablePpg) {
    return true;
  }
  if (g_ppgMqttQueue == nullptr) {
    return false;
  }

  const uint16_t ecgPressure = queueFillPermille(g_ecgMqttQueue, kEcgMqttQueueLen);
  if (ecgPressure >= kEcgQueueCriticalPressurePermille) {
    ++g_dropPpg;
    return false;
  }

  const uint16_t ppgPressure = queueFillPermille(g_ppgMqttQueue, kPpgMqttQueueLen);
  if (ppgPressure >= kPpgQueueHighPressurePermille) {
    ++g_ppgPressureDecimateCounter;
    if ((g_ppgPressureDecimateCounter & 0x01U) == 0U) {
      ++g_dropPpg;
      return false;
    }
  }

  bool overwrote = false;
  if (enqueueDroppingOldest(g_ppgMqttQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwritePpg;
      ++g_dropPpg;
    }
    return true;
  }
  ++g_dropPpg;
  return false;
}

bool enqueueImu(const ImuSample& sample) {
  if (kDemoWifiMode) {
    return true;
  }
  if (!g_enableImu) {
    return true;
  }
  if (g_imuMqttQueue == nullptr) {
    return false;
  }

  const uint16_t ecgPressure = queueFillPermille(g_ecgMqttQueue, kEcgMqttQueueLen);
  if (ecgPressure >= kEcgQueueHighPressurePermille) {
    ++g_dropImu;
    return false;
  }

  const uint16_t ppgPressure = queueFillPermille(g_ppgMqttQueue, kPpgMqttQueueLen);
  if (ppgPressure >= kPpgQueueHighPressurePermille) {
    ++g_dropImu;
    return false;
  }

  const uint16_t imuPressure = queueFillPermille(g_imuMqttQueue, kImuMqttQueueLen);
  if (imuPressure >= kImuQueueHighPressurePermille) {
    ++g_imuPressureDecimateCounter;
    if ((g_imuPressureDecimateCounter % 3U) != 0U) {
      ++g_dropImu;
      return false;
    }
  }

  bool overwrote = false;
  if (enqueueDroppingOldest(g_imuMqttQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwriteImu;
      ++g_dropImu;
    }
    return true;
  }
  ++g_dropImu;
  return false;
}

void taskLoop() {
  TickType_t lastWake = xTaskGetTickCount();

  for (;;) {
    if (ensureWifiConnected() && ensureMqttConnected()) {
      publishDiagTelemetry();
      for (uint8_t burst = 0; burst < kPublishBurstsPerLoop; ++burst) {
        publishEcgSamples();
        publishPpgSamples();
        publishImuSamples();
      }
      g_mqttClient.loop();
    } else {
      // Keep MQTT client state machine moving during reconnect windows.
      g_mqttClient.loop();
    }

    vTaskDelayUntil(&lastWake, kMqttTaskPeriodTicks);
  }
}

}  // namespace cloud_mqtt
