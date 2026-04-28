#include <Arduino.h>

#include <cstdio>
#include <cstring>

#include <driver/uart.h>

#include "config.h"
#include "ble_stream.h"
#include "cloud_mqtt.h"
#include "data_logger.h"
#include "ecg_adc.h"
#include "imu_bmi160.h"
#include "ppg_max30102.h"

namespace {

QueueHandle_t g_ecgQueue = nullptr;
QueueHandle_t g_ppgQueue = nullptr;
QueueHandle_t g_imuQueue = nullptr;

struct TxPacket {
  uint16_t len;
  uint8_t data[96];
};

QueueHandle_t g_uartTxQueue = nullptr;

bool g_ppgOnline = false;
bool g_imuOnline = false;

TickType_t g_ppgLastSampleTick = 0;
TickType_t g_imuLastSampleTick = 0;

constexpr TickType_t kPpgPeriodTicks = pdMS_TO_TICKS(PPG_SAMPLE_PERIOD_US / 1000U);
constexpr TickType_t kImuPeriodTicks = pdMS_TO_TICKS(BMI_SAMPLE_PERIOD_US / 1000U);
constexpr TickType_t kEcgPeriodTicks = pdMS_TO_TICKS(2);
constexpr TickType_t kSensorStallTimeout = pdMS_TO_TICKS(2000);
constexpr TickType_t kReinitRetryInterval = pdMS_TO_TICKS(1000);
constexpr uint8_t kEcgMaxSamplesPerLoop = 2;
constexpr uint32_t kPacketizerYieldEveryLoops = 20;
constexpr size_t kPacketizerEcgBatch = 8;
constexpr size_t kPacketizerPpgBatch = 4;
constexpr size_t kPacketizerImuBatch = 4;
constexpr bool kEnableUartStream = (ENABLE_UART_OUTPUT == 1);
constexpr bool kEnableWifiOutput = (ENABLE_WIFI_OUTPUT == 1);
constexpr bool kEnableBleOutput = (ENABLE_BLE_OUTPUT == 1);

uint32_t g_ecgDropCount = 0;

// LOGGER_OUTPUT_MODE supports only: 1 = compact text, 2 = binary.
#if LOGGER_OUTPUT_MODE == 1
constexpr bool kOutVerboseText = false;
constexpr bool kOutCompactText = true;
constexpr bool kOutBinary = false;
#elif LOGGER_OUTPUT_MODE == 2
constexpr bool kOutVerboseText = false;
constexpr bool kOutCompactText = false;
constexpr bool kOutBinary = true;
#else
#error "Unsupported LOGGER_OUTPUT_MODE"
#endif

constexpr uint8_t kSof1 = 0xA5;
constexpr uint8_t kSof2 = 0x5A;

uint8_t checksum8(const uint8_t type, const uint8_t len, const uint8_t* payload) {
  uint8_t sum = type ^ len;
  for (uint8_t i = 0; i < len; ++i) {
    sum ^= payload[i];
  }
  return sum;
}

bool pushTxPacket(const uint8_t* data, const size_t len) {
  if (!kEnableUartStream || g_uartTxQueue == nullptr) {
    return false;
  }
  if (len == 0 || len > sizeof(TxPacket::data)) {
    return false;
  }
  TxPacket pkt{};
  pkt.len = static_cast<uint16_t>(len);
  memcpy(pkt.data, data, len);
  return xQueueSend(g_uartTxQueue, &pkt, 0) == pdPASS;
}

bool pushBinaryFrame(const uint8_t type, const void* payload, const uint8_t payloadLen) {
  uint8_t frame[96] = {};
  const uint8_t* pl = static_cast<const uint8_t*>(payload);
  const size_t total = static_cast<size_t>(payloadLen) + 5U;
  if (total > sizeof(frame)) {
    return false;
  }

  frame[0] = kSof1;
  frame[1] = kSof2;
  frame[2] = type;
  frame[3] = payloadLen;
  memcpy(&frame[4], pl, payloadLen);
  frame[4 + payloadLen] = checksum8(type, payloadLen, pl);
  return pushTxPacket(frame, total);
}

bool pushTextLine(const char* line) {
  return pushTxPacket(reinterpret_cast<const uint8_t*>(line), strlen(line));
}

#pragma pack(push, 1)
struct EcgPayloadBin {
  uint64_t ts_us;
  uint16_t raw_adc;
  uint8_t lod_p;
  uint8_t lod_n;
};

struct PpgPayloadBin {
  uint64_t ts_us;
  uint32_t ir;
  uint32_t red;
};

struct ImuPayloadBin {
  uint64_t ts_us;
  int16_t ax;
  int16_t ay;
  int16_t az;
  int16_t gx;
  int16_t gy;
  int16_t gz;
};
#pragma pack(pop)

void emitEcg(const EcgSample& s) {
  if (kEnableWifiOutput) {
    (void)cloud_mqtt::enqueueEcg(s);
  }
  if (kEnableBleOutput) {
    (void)ble_stream::enqueueEcg(s);
  }
  if (kEnableUartStream && kOutBinary) {
    const EcgPayloadBin p{ s.ts_us, s.raw_adc,
                           static_cast<uint8_t>(s.lead_off_plus ? 1 : 0),
                           static_cast<uint8_t>(s.lead_off_minus ? 1 : 0) };
    (void)pushBinaryFrame('E', &p, static_cast<uint8_t>(sizeof(p)));
  }

  if (kEnableUartStream && (kOutVerboseText || kOutCompactText)) {
    char line[64];
    if (kOutVerboseText) {
      snprintf(line, sizeof(line), "ECG,%llu,%u,%u,%u\n", s.ts_us, s.raw_adc,
               s.lead_off_plus ? 1 : 0, s.lead_off_minus ? 1 : 0);
    } else {
      snprintf(line, sizeof(line), "E,%llu,%u,%u,%u\n", s.ts_us, s.raw_adc,
               s.lead_off_plus ? 1 : 0, s.lead_off_minus ? 1 : 0);
    }
    (void)pushTextLine(line);
  }
}

void emitPpg(const PpgSample& s) {
  if (kEnableWifiOutput) {
    (void)cloud_mqtt::enqueuePpg(s);
  }
  if (kEnableBleOutput) {
    (void)ble_stream::enqueuePpg(s);
  }
  if (kEnableUartStream && kOutBinary) {
    const PpgPayloadBin p{ s.ts_us, s.ir, s.red };
    (void)pushBinaryFrame('P', &p, static_cast<uint8_t>(sizeof(p)));
  }

  if (kEnableUartStream && (kOutVerboseText || kOutCompactText)) {
    char line[64];
    if (kOutVerboseText) {
      snprintf(line, sizeof(line), "PPG,%llu,%lu,%lu\n", s.ts_us,
               static_cast<unsigned long>(s.ir), static_cast<unsigned long>(s.red));
    } else {
      snprintf(line, sizeof(line), "P,%llu,%lu,%lu\n", s.ts_us,
               static_cast<unsigned long>(s.ir), static_cast<unsigned long>(s.red));
    }
    (void)pushTextLine(line);
  }
}

void emitImu(const ImuSample& s) {
  if (kEnableWifiOutput) {
    (void)cloud_mqtt::enqueueImu(s);
  }
  if (kEnableBleOutput) {
    (void)ble_stream::enqueueImu(s);
  }
  if (kEnableUartStream && kOutBinary) {
    const ImuPayloadBin p{ s.ts_us, s.acc_x, s.acc_y, s.acc_z, s.gyr_x, s.gyr_y, s.gyr_z };
    (void)pushBinaryFrame('I', &p, static_cast<uint8_t>(sizeof(p)));
  }

  if (kEnableUartStream && (kOutVerboseText || kOutCompactText)) {
    char line[96];
    if (kOutVerboseText) {
      snprintf(line, sizeof(line), "IMU,%llu,%d,%d,%d,%d,%d,%d\n", s.ts_us,
               s.acc_x, s.acc_y, s.acc_z, s.gyr_x, s.gyr_y, s.gyr_z);
    } else {
      snprintf(line, sizeof(line), "I,%llu,%d,%d,%d,%d,%d,%d\n", s.ts_us,
               s.acc_x, s.acc_y, s.acc_z, s.gyr_x, s.gyr_y, s.gyr_z);
    }
    (void)pushTextLine(line);
  }
}

bool bringUpPpg(const bool recoveryMode) {
  if (!ppg_max30102::begin()) {
    data_logger::logStatus(recoveryMode ? "MAX30102 reinit failed." : "MAX30102 init failed.");
    return false;
  }
  g_ppgLastSampleTick = xTaskGetTickCount();
  data_logger::logStatus(recoveryMode ? "MAX30102 recovered." : "MAX30102 ready.");
  return true;
}

bool bringUpImu(const bool recoveryMode) {
  if (!imu_bmi160::begin()) {
    char msg[128];
    snprintf(msg, sizeof(msg),
             "%s chip id=0x%02X, spiMode=%u, pmu=0x%02X, status=0x%02X, err=0x%02X",
             recoveryMode ? "BMI160 reinit failed," : "BMI160 init failed,",
             imu_bmi160::chipId(), imu_bmi160::spiMode(), imu_bmi160::pmuStatus(),
             imu_bmi160::statusReg(), imu_bmi160::errorReg());
    data_logger::logStatus(msg);
    return false;
  }
  g_imuLastSampleTick = xTaskGetTickCount();
  data_logger::logStatus(recoveryMode ? "BMI160 recovered." : "BMI160 ready.");
  return true;
}

void ecgTask(void* /*pvParameters*/) {
  TickType_t lastWake = xTaskGetTickCount();
  for (;;) {
    uint8_t processed = 0;
    EcgSample sample{};
    while (processed < kEcgMaxSamplesPerLoop && ecg_adc::sampleOnce(sample)) {
      ++processed;
      if (xQueueSend(g_ecgQueue, &sample, pdMS_TO_TICKS(10)) != pdPASS) {
        ++g_ecgDropCount;
      }
    }

    if (processed == 0) {
      vTaskDelay(pdMS_TO_TICKS(1));
    }

    taskYIELD();
    vTaskDelayUntil(&lastWake, kEcgPeriodTicks);
  }
}

void ppgTask(void* /*pvParameters*/) {
  TickType_t lastWake = xTaskGetTickCount();
  TickType_t lastRetryTick = 0;

  for (;;) {
    const TickType_t now = xTaskGetTickCount();

    if (!g_ppgOnline) {
      if ((now - lastRetryTick) >= kReinitRetryInterval) {
        lastRetryTick = now;
        g_ppgOnline = bringUpPpg(true);
      }
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    const size_t pushed = ppg_max30102::service(g_ppgQueue);
    if (pushed > 0) {
      g_ppgLastSampleTick = now;
    } else if ((now - g_ppgLastSampleTick) > kSensorStallTimeout) {
      g_ppgOnline = false;
      data_logger::logStatus("MAX30102 stalled, entering recovery.");
    }

    vTaskDelayUntil(&lastWake, kPpgPeriodTicks);
  }
}

void imuTask(void* /*pvParameters*/) {
  TickType_t lastWake = xTaskGetTickCount();
  TickType_t lastRetryTick = 0;

  for (;;) {
    const TickType_t now = xTaskGetTickCount();

    if (!g_imuOnline) {
      if ((now - lastRetryTick) >= kReinitRetryInterval) {
        lastRetryTick = now;
        g_imuOnline = bringUpImu(true);
      }
      vTaskDelay(pdMS_TO_TICKS(20));
      continue;
    }

    const size_t pushed = imu_bmi160::service(g_imuQueue);
    if (pushed > 0) {
      g_imuLastSampleTick = now;
    } else if ((now - g_imuLastSampleTick) > kSensorStallTimeout) {
      g_imuOnline = false;
      data_logger::logStatus("BMI160 stalled, entering recovery.");
    }

    vTaskDelayUntil(&lastWake, kImuPeriodTicks);
  }
}

void packetizerTask(void* /*pvParameters*/) {
  if (kEnableUartStream && kOutVerboseText) {
    (void)pushTextLine("# type,ts_us,data...\n");
  } else if (kEnableUartStream && kOutCompactText) {
    (void)pushTextLine("# t,ts_us,data...\n");
  }

  uint32_t loopCount = 0;
  for (;;) {
    bool didWork = false;
    uint16_t processed = 0;

    EcgSample ecg{};
    for (size_t i = 0; i < kPacketizerEcgBatch; ++i) {
      if (xQueueReceive(g_ecgQueue, &ecg, 0) != pdPASS) {
        break;
      }
      emitEcg(ecg);
      didWork = true;
      ++processed;
    }

    PpgSample ppg{};
    for (size_t i = 0; i < kPacketizerPpgBatch; ++i) {
      if (xQueueReceive(g_ppgQueue, &ppg, 0) != pdPASS) {
        break;
      }
      emitPpg(ppg);
      didWork = true;
      ++processed;
    }

    ImuSample imu{};
    for (size_t i = 0; i < kPacketizerImuBatch; ++i) {
      if (xQueueReceive(g_imuQueue, &imu, 0) != pdPASS) {
        break;
      }
      emitImu(imu);
      didWork = true;
      ++processed;
    }

    if (!didWork) {
      vTaskDelay(pdMS_TO_TICKS(1));
    } else {
      loopCount += processed;
      if ((loopCount % kPacketizerYieldEveryLoops) == 0U) {
        vTaskDelay(pdMS_TO_TICKS(1));
      } else {
        taskYIELD();
      }
    }
  }
}

void uartTxTask(void* /*pvParameters*/) {
  TxPacket pkt{};
  for (;;) {
    if (xQueueReceive(g_uartTxQueue, &pkt, portMAX_DELAY) == pdPASS) {
      if (pkt.len > 0) {
        (void)uart_write_bytes(UART_NUM_0,
                               reinterpret_cast<const char*>(pkt.data),
                               pkt.len);
      }
    }
  }
}

void mqttTask(void* /*pvParameters*/) {
  cloud_mqtt::taskLoop();
}

void bleTask(void* /*pvParameters*/) {
  ble_stream::taskLoop();
}

void createQueues() {
  g_ecgQueue = xQueueCreate(ECG_QUEUE_LEN, sizeof(EcgSample));
  g_ppgQueue = xQueueCreate(PPG_QUEUE_LEN, sizeof(PpgSample));
  g_imuQueue = xQueueCreate(IMU_QUEUE_LEN, sizeof(ImuSample));
  if (kEnableUartStream) {
    g_uartTxQueue = xQueueCreate(256, sizeof(TxPacket));
  } else {
    g_uartTxQueue = nullptr;
  }
}

void createTasks() {
  bool taskCreateFailed = false;

  if (xTaskCreatePinnedToCore(ecgTask, "ecg_task", ECG_TASK_STACK, nullptr,
                              ECG_TASK_PRIORITY, nullptr, 0) != pdPASS) {
    taskCreateFailed = true;
  }
  if (xTaskCreatePinnedToCore(ppgTask, "ppg_task", PPG_TASK_STACK, nullptr,
                              PPG_TASK_PRIORITY, nullptr, 0) != pdPASS) {
    taskCreateFailed = true;
  }
  if (xTaskCreatePinnedToCore(imuTask, "imu_task", IMU_TASK_STACK, nullptr,
                              IMU_TASK_PRIORITY, nullptr, 0) != pdPASS) {
    taskCreateFailed = true;
  }

  if (kEnableWifiOutput || kEnableUartStream || kEnableBleOutput) {
    if (xTaskCreatePinnedToCore(packetizerTask, "pkt_task", LOGGER_TASK_STACK,
                                nullptr, LOGGER_TASK_PRIORITY, nullptr, 1) != pdPASS) {
      taskCreateFailed = true;
    }
  }
  if (kEnableUartStream) {
    if (xTaskCreatePinnedToCore(uartTxTask, "uart_tx_task", LOGGER_TASK_STACK,
                                nullptr, UART_TASK_PRIORITY, nullptr, 1) != pdPASS) {
      taskCreateFailed = true;
    }
  }

  if (kEnableWifiOutput) {
    if (xTaskCreatePinnedToCore(mqttTask, "mqtt_task", 6144, nullptr,
                                MQTT_TASK_PRIORITY, nullptr, 0) != pdPASS) {
      taskCreateFailed = true;
    }
  }

  if (kEnableBleOutput) {
    if (xTaskCreatePinnedToCore(bleTask, "ble_task", BLE_TASK_STACK, nullptr,
                                BLE_TASK_PRIORITY, nullptr, 0) != pdPASS) {
      taskCreateFailed = true;
    }
  }

  if (taskCreateFailed) {
    data_logger::logStatus(F("Task creation failed."));
    while (true) {
      delay(1000);
    }
  }
}

}  // namespace

void setup() {
  data_logger::begin(DEBUG_BAUDRATE);
  if (kEnableUartStream) {
#if !ENABLE_SERIAL_LOGGER
    Serial.begin(DEBUG_BAUDRATE);
    delay(20);
#endif
    Serial.setTxBufferSize(4096);
  }
  data_logger::logStatus(F("Initializing biosignal acquisition project..."));

  if (kEnableWifiOutput) {
    cloud_mqtt::begin();
  }
  if (kEnableBleOutput) {
    ble_stream::begin();
  }
  createQueues();
  if (g_ecgQueue == nullptr || g_ppgQueue == nullptr || g_imuQueue == nullptr ||
      (kEnableUartStream && g_uartTxQueue == nullptr)) {
    data_logger::logStatus(F("Queue creation failed."));
    while (true) {
      delay(1000);
    }
  }

  g_ppgOnline = bringUpPpg(false);
  g_imuOnline = bringUpImu(false);

  ecg_adc::begin();
  ecg_adc::start();
  data_logger::logStatus(F("ECG ready."));

  createTasks();
}

void loop() { vTaskDelay(pdMS_TO_TICKS(1000)); }

