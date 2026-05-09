#include "ble_stream.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <stdlib.h>
#include <string>
#include <string.h>

#include "config.h"
#include "data_logger.h"
#include "signal_dsp.h"

namespace {

NimBLEServer* g_server = nullptr;
NimBLECharacteristic* g_notifyChar = nullptr;
NimBLECharacteristic* g_controlChar = nullptr;
QueueHandle_t g_ecgBleQueue = nullptr;
QueueHandle_t g_ppgBleQueue = nullptr;
QueueHandle_t g_imuBleQueue = nullptr;

bool g_connected = false;
bool g_subscribed = false;
bool g_enableEcg = true;
bool g_enablePpg = true;
bool g_enableImu = true;
uint16_t g_mtu = 23;
size_t g_notifyPayloadMax = BLE_NOTIFY_PAYLOAD_FALLBACK;

uint32_t g_bleSeq = 0;
uint32_t g_dropEcg = 0;
uint32_t g_dropPpg = 0;
uint32_t g_dropImu = 0;
uint32_t g_overwriteEcg = 0;
uint32_t g_overwritePpg = 0;
uint32_t g_overwriteImu = 0;
uint32_t g_notifyFail = 0;

constexpr size_t kBlePayloadBuffer = 512;
constexpr size_t kEcgBatchMax = 10;
constexpr size_t kPpgBatchMax = 6;
constexpr size_t kImuBatchMax = 4;
constexpr TickType_t kBleTaskPeriodTicks = pdMS_TO_TICKS(50);
constexpr uint8_t kNotifyMaxRetries = 3;
constexpr TickType_t kNotifyRetryDelay = pdMS_TO_TICKS(5);

size_t minSize(const size_t a, const size_t b) { return (a < b) ? a : b; }

void updateNotifyPayloadMax(const uint16_t mtu) {
  g_mtu = mtu;
  if (mtu >= 23) {
    g_notifyPayloadMax = static_cast<size_t>(mtu - 3);
  } else {
    g_notifyPayloadMax = BLE_NOTIFY_PAYLOAD_FALLBACK;
  }
}

class BleServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, ble_gap_conn_desc* desc) override {
    g_connected = true;
    g_subscribed = false;
    if (server != nullptr && desc != nullptr) {
      updateNotifyPayloadMax(server->getPeerMTU(desc->conn_handle));
    }
  }

  void onDisconnect(NimBLEServer* server) override {
    g_connected = false;
    g_subscribed = false;
    if (server != nullptr) {
      server->startAdvertising();
    }
  }

  void onMTUChange(uint16_t mtu, ble_gap_conn_desc* /*desc*/) override {
    updateNotifyPayloadMax(mtu);
  }
};

class BleCharCallbacks : public NimBLECharacteristicCallbacks {
  void onSubscribe(NimBLECharacteristic* /*c*/, ble_gap_conn_desc* /*desc*/, uint16_t subValue) override {
    g_subscribed = (subValue != 0);
  }
};

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

void resetCounters() {
  g_dropEcg = 0;
  g_dropPpg = 0;
  g_dropImu = 0;
  g_overwriteEcg = 0;
  g_overwritePpg = 0;
  g_overwriteImu = 0;
  g_notifyFail = 0;
}

void handleControlPayload(const char* payload) {
  if (payload == nullptr) {
    return;
  }
  if (textContains(payload, "reset_counters")) {
    resetCounters();
    data_logger::logStatus("[BLE] control reset_counters.");
    return;
  }
  if (textContains(payload, "set_channels")) {
    g_enableEcg = textContains(payload, "\"ecg\"");
    g_enablePpg = textContains(payload, "\"ppg\"") ||
                  textContains(payload, "\"ppg_ir\"") ||
                  textContains(payload, "\"ppg_red\"");
    g_enableImu = textContains(payload, "\"imu\"") ||
                  textContains(payload, "\"imu_ax\"") ||
                  textContains(payload, "\"imu_gx\"");
    data_logger::logStatus("[BLE] control set_channels.");
    return;
  }
  if (textContains(payload, "reset_dsp_state")) {
    signal_dsp::reset();
    data_logger::logStatus("[BLE] DSP state reset.");
    return;
  }
  if (textContains(payload, "set_dsp_enabled")) {
    signal_dsp::setEnabled(textContains(payload, "true") || textContains(payload, "\"enabled\":1"));
    data_logger::logStatus("[BLE] DSP enabled updated.");
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
    data_logger::logStatus("[BLE] DSP params updated.");
  }
}

class BleControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c) override {
    if (c == nullptr) {
      return;
    }
    const std::string value = c->getValue();
    char buffer[256];
    const size_t copyLen = value.size() < (sizeof(buffer) - 1U)
        ? value.size()
        : (sizeof(buffer) - 1U);
    memcpy(buffer, value.data(), copyLen);
    buffer[copyLen] = '\0';
    handleControlPayload(buffer);
  }
};

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
  payload[off++] = 1;
  payload[off++] = static_cast<uint8_t>(type);
  payload[off++] = 0;
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

size_t maxSamplesForNotify(const size_t sampleSize, const size_t hardMax) {
  if (g_notifyPayloadMax <= 19U || sampleSize == 0) {
    return 0;
  }
  return minSize(hardMax, (g_notifyPayloadMax - 19U) / sampleSize);
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

bool sendNotifyPayload(const uint8_t* payload, const size_t len) {
  if (!g_connected || !g_subscribed || g_notifyChar == nullptr || payload == nullptr) {
    return false;
  }
  if (len == 0) {
    return true;
  }

  if (len > g_notifyPayloadMax) {
    ++g_notifyFail;
    return false;
  }
  g_notifyChar->setValue(payload, len);
  // NimBLE-Arduino notify() returns void in this version. Treat as fire-and-forget.
  g_notifyChar->notify();
  return true;
}

void publishEcgSamples() {
  if (!g_enableEcg || g_ecgBleQueue == nullptr) {
    return;
  }

  EcgSample batch[kEcgBatchMax];
  const size_t batchMax = maxSamplesForNotify(12U, kEcgBatchMax);
  const size_t n = dequeueBatch(g_ecgBleQueue, batch, batchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_bleSeq++;

  uint8_t payload[kBlePayloadBuffer] = {};
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

  (void)sendNotifyPayload(payload, off);
}

void publishPpgSamples() {
  if (!g_enablePpg || g_ppgBleQueue == nullptr) {
    return;
  }

  PpgSample batch[kPpgBatchMax];
  const size_t batchMax = maxSamplesForNotify(16U, kPpgBatchMax);
  const size_t n = dequeueBatch(g_ppgBleQueue, batch, batchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_bleSeq++;

  uint8_t payload[kBlePayloadBuffer] = {};
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

  (void)sendNotifyPayload(payload, off);
}

void publishImuSamples() {
  if (!g_enableImu || g_imuBleQueue == nullptr) {
    return;
  }

  ImuSample batch[kImuBatchMax];
  const size_t batchMax = maxSamplesForNotify(20U, kImuBatchMax);
  const size_t n = dequeueBatch(g_imuBleQueue, batch, batchMax);
  if (n == 0) {
    return;
  }

  const uint32_t seq = g_bleSeq++;

  uint8_t payload[kBlePayloadBuffer] = {};
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

  (void)sendNotifyPayload(payload, off);
}

}  // namespace

namespace ble_stream {

void begin() {
  NimBLEDevice::init(BLE_DEVICE_NAME);
  (void)NimBLEDevice::setMTU(BLE_MTU_TARGET);

  g_server = NimBLEDevice::createServer();
  g_server->setCallbacks(new BleServerCallbacks());

  NimBLEService* service = g_server->createService(NimBLEUUID(BLE_SERVICE_UUID));
  g_notifyChar = service->createCharacteristic(NimBLEUUID(BLE_NOTIFY_CHAR_UUID), NIMBLE_PROPERTY::NOTIFY);
  g_controlChar = service->createCharacteristic(NimBLEUUID(BLE_CONTROL_CHAR_UUID), NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  g_notifyChar->setCallbacks(new BleCharCallbacks());
  g_controlChar->setCallbacks(new BleControlCallbacks());
  service->start();

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(service->getUUID());
  advertising->setScanResponse(true);
  advertising->start();

  if (g_ecgBleQueue == nullptr) {
    g_ecgBleQueue = xQueueCreate(BLE_ECG_QUEUE_LEN, sizeof(EcgSample));
  }
  if (g_ppgBleQueue == nullptr) {
    g_ppgBleQueue = xQueueCreate(BLE_PPG_QUEUE_LEN, sizeof(PpgSample));
  }
  if (g_imuBleQueue == nullptr) {
    g_imuBleQueue = xQueueCreate(BLE_IMU_QUEUE_LEN, sizeof(ImuSample));
  }

  updateNotifyPayloadMax(g_mtu);
  data_logger::logStatus("[BLE] NimBLE init done.");
}

bool enqueueEcg(const EcgSample& sample) {
  if (g_ecgBleQueue == nullptr) {
    return false;
  }
  bool overwrote = false;
  if (enqueueDroppingOldest(g_ecgBleQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwriteEcg;
    }
    return true;
  }
  ++g_dropEcg;
  return false;
}

bool enqueuePpg(const PpgSample& sample) {
  if (g_ppgBleQueue == nullptr) {
    return false;
  }
  bool overwrote = false;
  if (enqueueDroppingOldest(g_ppgBleQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwritePpg;
    }
    return true;
  }
  ++g_dropPpg;
  return false;
}

bool enqueueImu(const ImuSample& sample) {
  if (g_imuBleQueue == nullptr) {
    return false;
  }
  bool overwrote = false;
  if (enqueueDroppingOldest(g_imuBleQueue, sample, &overwrote)) {
    if (overwrote) {
      ++g_overwriteImu;
    }
    return true;
  }
  ++g_dropImu;
  return false;
}

void taskLoop() {
  TickType_t lastWake = xTaskGetTickCount();

  for (;;) {
    if (g_connected && g_subscribed) {
      publishEcgSamples();
      vTaskDelay(pdMS_TO_TICKS(2));  // Small gap between sensor types
      publishPpgSamples();
      vTaskDelay(pdMS_TO_TICKS(2));
      publishImuSamples();
    }

    vTaskDelayUntil(&lastWake, kBleTaskPeriodTicks);
  }
}

}  // namespace ble_stream
