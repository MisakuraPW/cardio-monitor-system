#include "cloud_mqtt.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_event.h>
#include <esp_idf_version.h>
#include <mqtt_client.h>
#include <stdlib.h>
#include <string.h>

#include "config.h"
#include "data_logger.h"
#include "m601_temp.h"
#include "signal_dsp.h"

namespace {

esp_mqtt_client_handle_t g_mqttClient = nullptr;

char g_clientId[48] = {};
uint32_t g_metricsSeq = 0;
uint32_t g_ecgSeq = 0;
uint32_t g_ppgSeq = 0;
uint32_t g_imuSeq = 0;
uint32_t g_tempSeq = 0;
uint32_t g_lastWifiRetryMs = 0;
uint32_t g_lastMqttStartAttemptMs = 0;
uint32_t g_lastDiagPublishMs = 0;
uint32_t g_lastNetPollLogMs = 0;
bool g_active = false;
bool g_wifiConnectInProgress = false;
bool g_mqttClientStarted = false;
volatile bool g_mqttConnected = false;
volatile bool g_publishOnlinePending = false;
volatile bool g_publishDiagPending = false;
uint32_t g_wifiConnectStartMs = 0;
constexpr bool kDemoWifiMode = true;
constexpr bool kDemoPublishRawWaveforms = !kDemoWifiMode;
constexpr bool kDemoPublishFilteredWaveforms = true;
bool g_enableEcg = true;
bool g_enablePpg = true;
bool g_enableImu = true;
bool g_enableTemp = true;

uint32_t g_dropEcg = 0;
uint32_t g_dropPpg = 0;
uint32_t g_dropImu = 0;
uint32_t g_dropTemp = 0;
uint32_t g_overwriteEcg = 0;
uint32_t g_overwritePpg = 0;
uint32_t g_overwriteImu = 0;
uint32_t g_overwriteTemp = 0;
uint32_t g_wifiReconnectCount = 0;
uint32_t g_mqttPublishFailCount = 0;
uint32_t g_mqttDisconnectCount = 0;
uint32_t g_mqttErrorCount = 0;
uint32_t g_mqttOutboxRejectCount = 0;
int g_mqttLastErrorType = 0;
int g_mqttLastConnectReturnCode = 0;
int g_mqttLastSockErr = 0;
int g_mqttLastTlsErr = 0;
uint32_t g_lastPublishLatencyMs = 0;
uint32_t g_imuPressureDecimateCounter = 0;
uint32_t g_demoImuDecimateCounter = 0;

constexpr size_t kEcgBatchMax = 160;
constexpr size_t kPpgBatchMax = 80;
constexpr size_t kImuBatchMax = 4;
constexpr size_t kTempBatchMax = 4;
constexpr uint32_t kWifiConnectTimeoutMs = 20000;
constexpr uint32_t kMqttStartRetryIntervalMs = 3000;
constexpr uint32_t kNetPollLogIntervalMs = 3000;
constexpr int kEspMqttTaskStack = 6144;
constexpr int kEspMqttTaskPriority = MQTT_TASK_PRIORITY;
constexpr int kMqttOutboxPressureBytes = 8192;
constexpr uint16_t kOutboxHighPressurePermille = 850;

constexpr size_t kMqttPayloadBuffer = 2048;
constexpr bool kJsonPayloadEnabled = (MQTT_PAYLOAD_MODE == 0) || (MQTT_PAYLOAD_MODE == 2);
constexpr bool kBinaryPayloadEnabled = (MQTT_PAYLOAD_MODE == 1) || (MQTT_PAYLOAD_MODE == 2);

static_assert((kEcgBatchMax * 12U + 19U) <= kMqttPayloadBuffer,
              "ECG BIO2 frame exceeds MQTT payload buffer");
static_assert((kPpgBatchMax * 16U + 19U) <= kMqttPayloadBuffer,
              "PPG BIO2 frame exceeds MQTT payload buffer");

char g_sessionId[48] = {};
char g_brokerUri[96] = {};
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
char g_topicTemperature[96] = {};
char g_topicWaveBinTemp[96] = {};

EcgSample g_ecgBatch[kEcgBatchMax] = {};
PpgSample g_ppgBatch[kPpgBatchMax] = {};
ImuSample g_imuBatch[kImuBatchMax] = {};
TemperatureSample g_tempBatch[kTempBatchMax] = {};
size_t g_ecgBatchCount = 0;
size_t g_ppgBatchCount = 0;
size_t g_imuBatchCount = 0;
size_t g_tempBatchCount = 0;
ImuSample g_latestImu = {};
TemperatureSample g_latestTemp = {};
bool g_hasLatestImu = false;
bool g_hasLatestTemp = false;

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

uint16_t outboxFillPermille() {
  if (g_mqttClient == nullptr || kMqttOutboxPressureBytes <= 0) {
    return 0;
  }
  const int bytes = esp_mqtt_client_get_outbox_size(g_mqttClient);
  if (bytes <= 0) {
    return 0;
  }
  return static_cast<uint16_t>((static_cast<uint32_t>(bytes) * 1000U) /
                               static_cast<uint32_t>(kMqttOutboxPressureBytes));
}

bool publishTextTracked(const char* topic, const char* payload, bool retained) {
  if (topic == nullptr || payload == nullptr) {
    return false;
  }
  if (g_mqttClient == nullptr || !g_mqttConnected) {
    ++g_mqttPublishFailCount;
    return false;
  }
  const int outboxBytes = esp_mqtt_client_get_outbox_size(g_mqttClient);
  if (outboxBytes >= kMqttOutboxPressureBytes) {
    ++g_mqttOutboxRejectCount;
    ++g_mqttPublishFailCount;
    return false;
  }

  const uint32_t t0 = millis();
  const int msgId = esp_mqtt_client_enqueue(g_mqttClient,
                                            topic,
                                            payload,
                                            static_cast<int>(strlen(payload)),
                                            0,
                                            retained ? 1 : 0,
                                            true);
  g_lastPublishLatencyMs = millis() - t0;
  if (msgId < 0) {
    ++g_mqttPublishFailCount;
    return false;
  }
  return true;
}

bool publishBinaryTracked(const char* topic, const uint8_t* payload, const size_t len, bool retained) {
  if (topic == nullptr || payload == nullptr || len == 0) {
    return false;
  }
  if (g_mqttClient == nullptr || !g_mqttConnected) {
    ++g_mqttPublishFailCount;
    return false;
  }

  const uint32_t t0 = millis();
  const int msgId = esp_mqtt_client_publish(g_mqttClient,
                                            topic,
                                            reinterpret_cast<const char*>(payload),
                                            static_cast<int>(len),
                                            0,
                                            retained ? 1 : 0);
  g_lastPublishLatencyMs = millis() - t0;
  if (msgId < 0) {
    ++g_mqttPublishFailCount;
    return false;
  }
  return true;
}

void buildClientId() {
  const uint64_t chipId = ESP.getEfuseMac();
  snprintf(g_clientId, sizeof(g_clientId), "%s-%04X", MQTT_CLIENT_ID_PREFIX,
           static_cast<unsigned>(chipId & 0xFFFFU));
  snprintf(g_sessionId, sizeof(g_sessionId), "%s-%04X", MQTT_SESSION_ID,
           static_cast<unsigned>(chipId & 0xFFFFU));
  snprintf(g_brokerUri, sizeof(g_brokerUri), "mqtt://%s:%u",
           MQTT_BROKER_HOST,
           static_cast<unsigned>(MQTT_BROKER_PORT));
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
  snprintf(g_topicTemperature, sizeof(g_topicTemperature), "%s/%s/temperature", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
  snprintf(g_topicWaveBinTemp, sizeof(g_topicWaveBinTemp), "%s/%s/waveform_bin/temp", MQTT_TOPIC_ROOT, MQTT_TOPIC_DEVICE_ID);
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

void publishOnlineStatus() {
  char onlinePayload[128];
  snprintf(onlinePayload, sizeof(onlinePayload),
           "{\"deviceId\":\"%s\",\"clientId\":\"%s\",\"sessionId\":\"%s\",\"status\":\"online\",\"timestampMs\":%lu}",
           MQTT_TOPIC_DEVICE_ID,
           g_clientId,
           g_sessionId,
           static_cast<unsigned long>(millis()));
  (void)publishTextTracked(g_topicStatus, onlinePayload, true);
}

void publishDeferredConnectTelemetry() {
  if (!g_mqttConnected) {
    return;
  }

  if (g_publishOnlinePending) {
    g_publishOnlinePending = false;
    publishOnlineStatus();
    g_publishDiagPending = true;
  }

  if (g_publishDiagPending) {
    g_publishDiagPending = false;
    g_lastDiagPublishMs = 0;
  }
}

void resetCounters() {
  g_dropEcg = 0;
  g_dropPpg = 0;
  g_dropImu = 0;
  g_dropTemp = 0;
  g_overwriteEcg = 0;
  g_overwritePpg = 0;
  g_overwriteImu = 0;
  g_overwriteTemp = 0;
  g_mqttPublishFailCount = 0;
  g_mqttDisconnectCount = 0;
  g_mqttErrorCount = 0;
  g_mqttOutboxRejectCount = 0;
  g_mqttLastErrorType = 0;
  g_mqttLastConnectReturnCode = 0;
  g_mqttLastSockErr = 0;
  g_mqttLastTlsErr = 0;
  g_wifiReconnectCount = 0;
  g_imuPressureDecimateCounter = 0;
  g_demoImuDecimateCounter = 0;
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
    g_enableImu = textContains(payload, "\"imu\"") ||
                  textContains(payload, "\"imu_ax\"") ||
                  textContains(payload, "\"imu_ay\"") ||
                  textContains(payload, "\"imu_az\"") ||
                  textContains(payload, "\"imu_gx\"") ||
                  textContains(payload, "\"imu_gy\"") ||
                  textContains(payload, "\"imu_gz\"");
    g_enableTemp = textContains(payload, "\"temp\"") ||
                   textContains(payload, "\"temperature\"");
    data_logger::logStatus("[NET] MQTT control set_channels.");
    return;
  }
  if (textContains(payload, "ping")) {
    g_publishDiagPending = true;
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

bool mqttEventTopicEquals(const esp_mqtt_event_handle_t event, const char* expected) {
  if (event == nullptr || expected == nullptr || event->topic == nullptr) {
    return false;
  }
  const int expectedLen = static_cast<int>(strlen(expected));
  return event->topic_len == expectedLen && strncmp(event->topic, expected, expectedLen) == 0;
}

void handleMqttData(const esp_mqtt_event_handle_t event) {
  if (!mqttEventTopicEquals(event, g_topicControl)) {
    return;
  }
  char buffer[256];
  const unsigned int limit = static_cast<unsigned int>(sizeof(buffer) - 1U);
  const unsigned int copyLen = event->data_len < static_cast<int>(limit)
      ? static_cast<unsigned int>(event->data_len)
      : limit;
  memcpy(buffer, event->data, copyLen);
  buffer[copyLen] = '\0';
  handleControlPayload(buffer);
}

void onMqttEvent(void* /*handlerArgs*/, esp_event_base_t /*base*/, int32_t eventId, void* eventData) {
  const esp_mqtt_event_handle_t event = static_cast<esp_mqtt_event_handle_t>(eventData);
  switch (eventId) {
    case MQTT_EVENT_CONNECTED:
      g_mqttConnected = true;
      g_publishOnlinePending = true;
      g_publishDiagPending = true;
      data_logger::logStatus("[NET] MQTT connected.");
      (void)esp_mqtt_client_subscribe(g_mqttClient, g_topicControl, 1);
      break;
    case MQTT_EVENT_DISCONNECTED:
      g_mqttConnected = false;
      ++g_mqttDisconnectCount;
      data_logger::logStatus("[NET] MQTT disconnected.");
      break;
    case MQTT_EVENT_DATA:
      handleMqttData(event);
      break;
    case MQTT_EVENT_ERROR:
      ++g_mqttErrorCount;
      if (event != nullptr && event->error_handle != nullptr) {
        g_mqttLastErrorType = static_cast<int>(event->error_handle->error_type);
        g_mqttLastConnectReturnCode = static_cast<int>(event->error_handle->connect_return_code);
        g_mqttLastSockErr = event->error_handle->esp_transport_sock_errno;
        g_mqttLastTlsErr = static_cast<int>(event->error_handle->esp_tls_last_esp_err);
        char msg[160];
        snprintf(msg, sizeof(msg),
                 "[NET] MQTT error type=%d rc=%d sock=%d tls=0x%x",
                 g_mqttLastErrorType,
                 g_mqttLastConnectReturnCode,
                 g_mqttLastSockErr,
                 g_mqttLastTlsErr);
        data_logger::logStatus(msg);
      } else {
        data_logger::logStatus("[NET] MQTT event error.");
      }
      break;
    default:
      break;
  }
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
    WiFi.disconnect(false, false);
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

bool ensureMqttStarted() {
  if (g_mqttClient == nullptr) {
    return false;
  }
  if (g_mqttClientStarted) {
    return g_mqttConnected;
  }
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  const uint32_t nowMs = millis();
  if ((nowMs - g_lastMqttStartAttemptMs) < kMqttStartRetryIntervalMs) {
    return false;
  }
  g_lastMqttStartAttemptMs = nowMs;

  const esp_err_t err = esp_mqtt_client_start(g_mqttClient);
  if (err != ESP_OK) {
    ++g_mqttPublishFailCount;
    char msg[128];
    snprintf(msg, sizeof(msg),
             "[NET] MQTT start failed err=0x%x heap=%lu",
             static_cast<unsigned>(err),
             static_cast<unsigned long>(ESP.getFreeHeap()));
    data_logger::logStatus(msg);
    return false;
  }
  g_mqttClientStarted = true;
  data_logger::logStatus("[NET] MQTT async client started.");
  return false;
}

bool ensureAsyncReady() {
  if (!g_active) {
    return false;
  }
  const bool wifiReady = ensureWifiConnected();
  const bool mqttReady = wifiReady && ensureMqttStarted();
  if (wifiReady && mqttReady) {
    publishDeferredConnectTelemetry();
    publishDiagTelemetry();
    return true;
  }
  return false;
}

void pollNetwork() {
  if (!g_active) {
    return;
  }
  const bool wifiReady = ensureWifiConnected();
  const bool mqttReady = wifiReady && ensureMqttStarted();
  if (wifiReady && mqttReady) {
    publishDeferredConnectTelemetry();
    publishDiagTelemetry();
    return;
  }

  const uint32_t nowMs = millis();
  if ((nowMs - g_lastNetPollLogMs) >= kNetPollLogIntervalMs) {
    g_lastNetPollLogMs = nowMs;
    char msg[128];
    snprintf(msg, sizeof(msg),
             "[NET] poll wifi=%d mqttStarted=%u mqttConnected=%u heap=%lu",
             static_cast<int>(WiFi.status()),
             g_mqttClientStarted ? 1U : 0U,
             g_mqttConnected ? 1U : 0U,
             static_cast<unsigned long>(ESP.getFreeHeap()));
    data_logger::logStatus(msg);
  }
}

void publishDiagTelemetry() {
  const uint32_t nowMs = millis();
  if ((nowMs - g_lastDiagPublishMs) < MQTT_PUBLISH_PERIOD_MS) {
    return;
  }
  g_lastDiagPublishMs = nowMs;

  const uint32_t qEcg = static_cast<uint32_t>(g_ecgBatchCount);
  const uint32_t qPpg = static_cast<uint32_t>(g_ppgBatchCount);
  const uint32_t qImu = static_cast<uint32_t>(g_imuBatchCount);
  const uint32_t qTemp = static_cast<uint32_t>(g_tempBatchCount);
  const signal_dsp::DspMetrics dsp = signal_dsp::metrics();
  const uint32_t tempCrcFails = m601_temp::crcFailCount();
  const uint32_t tempBusFails = m601_temp::busFailCount();
  const uint8_t tempFlags = m601_temp::lastStatusFlags();
  const int mqttOutboxBytes = (g_mqttClient == nullptr) ? 0 : esp_mqtt_client_get_outbox_size(g_mqttClient);
  const bool hasImu = g_hasLatestImu;
  const bool hasTemp = g_hasLatestTemp;

  char payload[kMqttPayloadBuffer];
  snprintf(payload, sizeof(payload),
           "{\"deviceId\":\"%s\",\"clientId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%lu,"
           "\"ecgQueueLen\":%lu,\"ppgQueueLen\":%lu,\"imuQueueLen\":%lu,"
           "\"tempQueueLen\":%lu,"
           "\"ecgDropCount\":%lu,\"ppgDropCount\":%lu,\"imuDropCount\":%lu,\"tempDropCount\":%lu,"
           "\"mqttPublishFailCount\":%lu,\"mqttDisconnectCount\":%lu,\"mqttErrorCount\":%lu,"
           "\"mqttOutboxRejectCount\":%lu,\"mqttLastErrorType\":%d,\"mqttLastConnectReturnCode\":%d,"
           "\"mqttLastSockErr\":%d,\"mqttLastTlsErr\":%d,"
           "\"mqttOutboxBytes\":%d,\"mqttConnected\":%s,\"wifiReconnectCount\":%lu,"
           "\"tempCrcFailCount\":%lu,\"tempBusFailCount\":%lu,\"tempStatusFlags\":%u,"
           "\"rssi\":%ld,\"heapFree\":%lu,\"lastPublishLatencyMs\":%lu,"
           "\"dsp\":{\"enabled\":%s,\"version\":%lu,\"motion\":%.3f,\"ecgQuality\":%.3f,\"ppgQuality\":%.3f,\"ecgBpm\":%.2f,\"ppgBpm\":%.2f},"
           "\"imu\":{\"present\":%s,\"tsUs\":%llu,\"ax\":%d,\"ay\":%d,\"az\":%d,\"gx\":%d,\"gy\":%d,\"gz\":%d},"
           "\"temp\":{\"present\":%s,\"tsUs\":%llu,\"raw\":%d,\"tempC\":%.4f,\"flags\":%u},"
           "\"ow\":{\"ecg\":%lu,\"ppg\":%lu,\"imu\":%lu,\"temp\":%lu}}",
           MQTT_TOPIC_DEVICE_ID,
           g_clientId,
           g_sessionId,
           static_cast<unsigned long>(g_metricsSeq++),
           static_cast<unsigned long>(nowMs),
           static_cast<unsigned long>(qEcg),
           static_cast<unsigned long>(qPpg),
           static_cast<unsigned long>(qImu),
           static_cast<unsigned long>(qTemp),
           static_cast<unsigned long>(g_dropEcg),
           static_cast<unsigned long>(g_dropPpg),
           static_cast<unsigned long>(g_dropImu),
           static_cast<unsigned long>(g_dropTemp),
           static_cast<unsigned long>(g_mqttPublishFailCount),
           static_cast<unsigned long>(g_mqttDisconnectCount),
           static_cast<unsigned long>(g_mqttErrorCount),
           static_cast<unsigned long>(g_mqttOutboxRejectCount),
           g_mqttLastErrorType,
           g_mqttLastConnectReturnCode,
           g_mqttLastSockErr,
           g_mqttLastTlsErr,
           mqttOutboxBytes,
           g_mqttConnected ? "true" : "false",
           static_cast<unsigned long>(g_wifiReconnectCount),
           static_cast<unsigned long>(tempCrcFails),
           static_cast<unsigned long>(tempBusFails),
           static_cast<unsigned>(tempFlags),
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
           hasImu ? "true" : "false",
           static_cast<unsigned long long>(hasImu ? g_latestImu.ts_us : 0ULL),
           hasImu ? static_cast<int>(g_latestImu.acc_x) : 0,
           hasImu ? static_cast<int>(g_latestImu.acc_y) : 0,
           hasImu ? static_cast<int>(g_latestImu.acc_z) : 0,
           hasImu ? static_cast<int>(g_latestImu.gyr_x) : 0,
           hasImu ? static_cast<int>(g_latestImu.gyr_y) : 0,
           hasImu ? static_cast<int>(g_latestImu.gyr_z) : 0,
           hasTemp ? "true" : "false",
           static_cast<unsigned long long>(hasTemp ? g_latestTemp.ts_us : 0ULL),
           hasTemp ? static_cast<int>(g_latestTemp.raw) : 0,
           static_cast<double>(hasTemp ? g_latestTemp.temp_c : 0.0f),
           hasTemp ? static_cast<unsigned>(g_latestTemp.flags) : 0,
           static_cast<unsigned long>(g_overwriteEcg),
           static_cast<unsigned long>(g_overwritePpg),
           static_cast<unsigned long>(g_overwriteImu),
           static_cast<unsigned long>(g_overwriteTemp));

  (void)publishTextTracked(g_topicMetrics, payload, false);
}

void publishEcgBatch(const EcgSample* batch, const size_t n) {
  if (batch == nullptr || n == 0) {
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
      g_dropEcg += static_cast<uint32_t>(n);
      data_logger::logStatus("[NET] MQTT ECG filtered BIN publish failed.");
    }
  }
}

void publishPpgBatch(const PpgSample* batch, const size_t n) {
  if (batch == nullptr || n == 0) {
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
      g_dropPpg += static_cast<uint32_t>(n);
      data_logger::logStatus("[NET] MQTT PPG filtered BIN publish failed.");
    }
  }
}

void publishImuBatch(const ImuSample* batch, const size_t n) {
  if (batch == nullptr || n == 0) {
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

void publishTemperatureBatch(const TemperatureSample* batch, const size_t n) {
  if (batch == nullptr || n == 0) {
    return;
  }

  const uint32_t seq = g_tempSeq++;

  if (kJsonPayloadEnabled) {
    char payload[kMqttPayloadBuffer];
    int w = snprintf(payload, sizeof(payload),
                     "{\"deviceId\":\"%s\",\"sessionId\":\"%s\",\"seq\":%lu,\"timestampMs\":%llu,\"sampleRate\":%lu,\"unit\":\"C\",\"samples\":[",
                     MQTT_TOPIC_DEVICE_ID,
                     g_sessionId,
                     static_cast<unsigned long>(seq),
                     static_cast<unsigned long long>(tsUsToMs(batch[0].ts_us)),
                     static_cast<unsigned long>(M601_SAMPLE_RATE_HZ));
    if (w > 0 && static_cast<size_t>(w) < sizeof(payload)) {
      size_t off = static_cast<size_t>(w);
      bool ok = true;
      for (size_t i = 0; i < n; ++i) {
        w = snprintf(payload + off, sizeof(payload) - off,
                     "%s{\"tsUs\":%llu,\"raw\":%d,\"tempC\":%.4f,\"flags\":%u}",
                     (i == 0) ? "" : ",",
                     static_cast<unsigned long long>(batch[i].ts_us),
                     static_cast<int>(batch[i].raw),
                     static_cast<double>(batch[i].temp_c),
                     static_cast<unsigned>(batch[i].flags));
        if (w <= 0 || static_cast<size_t>(w) >= (sizeof(payload) - off)) {
          ok = false;
          break;
        }
        off += static_cast<size_t>(w);
      }
      if (ok && off + 3 < sizeof(payload)) {
        payload[off++] = ']';
        payload[off++] = '}';
        payload[off] = '\0';
        if (!publishTextTracked(g_topicTemperature, payload, false)) {
          data_logger::logStatus("[NET] MQTT temperature publish failed.");
        }
      }
    }
  }

  if (kBinaryPayloadEnabled) {
    uint8_t payload[kMqttPayloadBuffer] = {};
    const uint16_t payloadLen = static_cast<uint16_t>(n * 15U);
    const size_t payloadOffset = beginBio2Frame(payload, sizeof(payload), 'T', seq, static_cast<uint16_t>(n), payloadLen);
    size_t off = payloadOffset;

    for (size_t i = 0; i < n; ++i) {
      if (off + 15 > sizeof(payload)) {
        break;
      }
      appendU64Le(&payload[off], batch[i].ts_us);
      off += 8;
      appendU16Le(&payload[off], static_cast<uint16_t>(batch[i].raw));
      off += 2;
      static_assert(sizeof(float) == 4, "ESP32 float must be 32-bit");
      memcpy(&payload[off], &batch[i].temp_c, sizeof(float));
      off += 4;
      payload[off++] = batch[i].flags;
    }
    finishBio2Frame(payload, payloadOffset, off - payloadOffset);

    if (!publishBinaryTracked(g_topicWaveBinTemp, payload, off, false)) {
      data_logger::logStatus("[NET] MQTT temperature BIN publish failed.");
    }
  }
}

}  // namespace

namespace cloud_mqtt {

void begin() {
  buildClientId();
  buildTopics();

  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setSleep(WIFI_PS_NONE);
  WiFi.setAutoReconnect(true);

  if (g_mqttClient == nullptr) {
    esp_mqtt_client_config_t mqttConfig = {};
#if ESP_IDF_VERSION_MAJOR >= 5
    mqttConfig.broker.address.uri = g_brokerUri;
    mqttConfig.credentials.client_id = g_clientId;
    mqttConfig.session.keepalive = 45;
    mqttConfig.network.disable_auto_reconnect = false;
    mqttConfig.network.reconnect_timeout_ms = MQTT_RETRY_INTERVAL_MS;
    mqttConfig.network.timeout_ms = 1000;
    mqttConfig.task.stack_size = kEspMqttTaskStack;
    mqttConfig.task.priority = kEspMqttTaskPriority;
    mqttConfig.buffer.size = kMqttPayloadBuffer + 64;
    mqttConfig.buffer.out_size = kMqttPayloadBuffer + 64;
#else
    mqttConfig.uri = g_brokerUri;
    mqttConfig.client_id = g_clientId;
    mqttConfig.keepalive = 45;
    mqttConfig.disable_auto_reconnect = false;
    mqttConfig.reconnect_timeout_ms = MQTT_RETRY_INTERVAL_MS;
    mqttConfig.network_timeout_ms = 1000;
    mqttConfig.task_stack = kEspMqttTaskStack;
    mqttConfig.task_prio = kEspMqttTaskPriority;
    mqttConfig.buffer_size = kMqttPayloadBuffer + 64;
    mqttConfig.out_buffer_size = kMqttPayloadBuffer + 64;
#endif

    g_mqttClient = esp_mqtt_client_init(&mqttConfig);
    if (g_mqttClient == nullptr) {
      data_logger::logStatus("[NET] MQTT async client init failed.");
    } else {
      (void)esp_mqtt_client_register_event(g_mqttClient,
                                           MQTT_EVENT_ANY,
                                           onMqttEvent,
                                           nullptr);
    }
  }

  char msg[128];
  snprintf(msg, sizeof(msg), "[NET] MQTT async init uri=%s id=%s ecgBin=%s",
           g_brokerUri, g_clientId, g_topicWaveBinEcg);
  data_logger::logStatus(msg);
}

void setActive(const bool active) {
  if (g_active == active) {
    return;
  }

  g_active = active;
  if (active) {
    if (g_mqttClient == nullptr) {
      begin();
    }
    WiFi.persistent(false);
    WiFi.mode(WIFI_STA);
    WiFi.setSleep(false);
    WiFi.setSleep(WIFI_PS_NONE);
    WiFi.setAutoReconnect(true);
    WiFi.disconnect(false, false);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    g_wifiConnectInProgress = true;
    g_wifiConnectStartMs = millis();
    g_lastWifiRetryMs = g_wifiConnectStartMs;
    g_lastMqttStartAttemptMs = 0;
    g_lastNetPollLogMs = 0;
    data_logger::logStatus("[NET] WiFi/MQTT output active.");
  } else {
    if (g_mqttClient != nullptr && g_mqttClientStarted) {
      (void)esp_mqtt_client_stop(g_mqttClient);
    }
    if (g_mqttClient != nullptr) {
      (void)esp_mqtt_client_destroy(g_mqttClient);
      g_mqttClient = nullptr;
    }
    g_mqttClientStarted = false;
    g_mqttConnected = false;
    g_publishOnlinePending = false;
    g_publishDiagPending = false;
    g_lastMqttStartAttemptMs = 0;
    g_lastNetPollLogMs = 0;
    WiFi.disconnect(false, false);
    WiFi.mode(WIFI_OFF);
    g_ecgBatchCount = 0;
    g_ppgBatchCount = 0;
    g_imuBatchCount = 0;
    g_tempBatchCount = 0;
    g_wifiConnectInProgress = false;
    data_logger::logStatus("[NET] WiFi/MQTT output inactive.");
  }
}

void poll() {
  pollNetwork();
}

bool enqueueEcg(const EcgSample& sample) {
  if (!g_active) {
    return true;
  }
  if (!g_enableEcg) {
    return true;
  }
  if (!ensureAsyncReady()) {
    return true;
  }
  g_ecgBatch[g_ecgBatchCount++] = sample;
  if (g_ecgBatchCount >= kEcgBatchMax) {
    publishEcgBatch(g_ecgBatch, g_ecgBatchCount);
    g_ecgBatchCount = 0;
  }
  return true;
}

bool enqueuePpg(const PpgSample& sample) {
  if (!g_active) {
    return true;
  }
  if (!g_enablePpg) {
    return true;
  }
  if (!ensureAsyncReady()) {
    return true;
  }
  g_ppgBatch[g_ppgBatchCount++] = sample;
  if (g_ppgBatchCount >= kPpgBatchMax) {
    publishPpgBatch(g_ppgBatch, g_ppgBatchCount);
    g_ppgBatchCount = 0;
  }
  return true;
}

bool enqueueImu(const ImuSample& sample) {
  if (!g_active) {
    return true;
  }
  if (kDemoWifiMode) {
    ++g_demoImuDecimateCounter;
    if ((g_demoImuDecimateCounter % 20U) != 0U) {
      return true;
    }
  }
  g_latestImu = sample;
  g_hasLatestImu = true;
  if (!g_enableImu) {
    return true;
  }
  return true;
}

bool enqueueTemperature(const TemperatureSample& sample) {
  if (!g_active) {
    return true;
  }
  if (!g_enableTemp) {
    return true;
  }
  g_latestTemp = sample;
  g_hasLatestTemp = true;
  return true;
}

void taskLoop() {
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
  }
}

}  // namespace cloud_mqtt
