#include "m601_temp.h"

#include "config.h"
#include "time_sync.h"

#include <driver/gpio.h>

namespace {

constexpr uint8_t kCmdSkipRom = 0xCC;
constexpr uint8_t kCmdReadRom = 0x33;
constexpr uint8_t kCmdConvertT = 0x44;
constexpr uint8_t kCmdReadScratchpad = 0xBE;
constexpr uint16_t kResetLowUs = 960;
constexpr uint16_t kResetLowUsLowVoltageFallback = 2000;
constexpr uint16_t kWriteOneLowUs = 3;
constexpr uint16_t kWriteZeroLowUs = 90;
constexpr uint16_t kWriteSlotUs = 120;
constexpr uint16_t kReadInitLowUs = 2;
constexpr uint16_t kReadSampleUs = 8;
constexpr uint16_t kReadSlotUs = 70;

portMUX_TYPE g_oneWireMux = portMUX_INITIALIZER_UNLOCKED;
uint32_t g_crcFailCount = 0;
uint32_t g_busFailCount = 0;
uint8_t g_lastStatusFlags = 0;
const char* g_lastFailureStage = "none";
uint8_t g_lastScratchpad[9] = {};
uint8_t g_lastRom[8] = {};
uint8_t g_lastCrcCalculated = 0;
uint8_t g_lastCrcRead = 0;

void releaseBus() {
  gpio_set_level(M601_DQ_PIN, 1);
}

void pullBusLow() {
  gpio_set_level(M601_DQ_PIN, 0);
}

void configureBus() {
  gpio_config_t ioConf = {};
  ioConf.pin_bit_mask = 1ULL << static_cast<uint8_t>(M601_DQ_PIN);
  ioConf.mode = GPIO_MODE_INPUT_OUTPUT_OD;
  ioConf.pull_up_en = GPIO_PULLUP_ENABLE;
  ioConf.pull_down_en = GPIO_PULLDOWN_DISABLE;
  ioConf.intr_type = GPIO_INTR_DISABLE;
  gpio_config(&ioConf);
  releaseBus();
}

bool readBusHigh() {
  return gpio_get_level(M601_DQ_PIN) != 0;
}

bool resetPulse(const uint16_t resetLowUs = kResetLowUs) {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  delayMicroseconds(resetLowUs);
  releaseBus();

  bool present = false;
  delayMicroseconds(15);
  for (uint8_t i = 0; i < 48; ++i) {
    if (!readBusHigh()) {
      present = true;
    }
    delayMicroseconds(5);
  }
  delayMicroseconds(260);
  portEXIT_CRITICAL(&g_oneWireMux);
  return present;
}

void writeBit(const bool bitValue) {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  if (bitValue) {
    delayMicroseconds(kWriteOneLowUs);
    releaseBus();
    delayMicroseconds(kWriteSlotUs - kWriteOneLowUs);
  } else {
    delayMicroseconds(kWriteZeroLowUs);
    releaseBus();
    delayMicroseconds(kWriteSlotUs - kWriteZeroLowUs);
  }
  portEXIT_CRITICAL(&g_oneWireMux);
}

bool readBit() {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  delayMicroseconds(kReadInitLowUs);
  releaseBus();
  delayMicroseconds(kReadSampleUs);
  const bool value = readBusHigh();
  delayMicroseconds(kReadSlotUs - kReadInitLowUs - kReadSampleUs);
  portEXIT_CRITICAL(&g_oneWireMux);
  return value;
}

void writeByte(const uint8_t value) {
  for (uint8_t bit = 0; bit < 8; ++bit) {
    writeBit(((value >> bit) & 0x01U) != 0);
  }
}

uint8_t readByte() {
  uint8_t value = 0;
  for (uint8_t bit = 0; bit < 8; ++bit) {
    if (readBit()) {
      value |= static_cast<uint8_t>(1U << bit);
    }
  }
  return value;
}

uint8_t crc8Dallas(const uint8_t* data, const size_t len) {
  uint8_t crc = 0;
  for (size_t i = 0; i < len; ++i) {
    uint8_t inByte = data[i];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      const uint8_t mix = (crc ^ inByte) & 0x01U;
      crc >>= 1;
      if (mix != 0) {
        crc ^= 0x8CU;
      }
      inByte >>= 1;
    }
  }
  return crc;
}

bool startConversion() {
  if (!resetPulse()) {
    g_lastFailureStage = "convert_reset";
    return false;
  }
  writeByte(kCmdSkipRom);
  writeByte(kCmdConvertT);
  g_lastFailureStage = "convert_sent";
  return true;
}

bool waitForConversion() {
  delay(M601_CONVERSION_TIMEOUT_MS);
  g_lastFailureStage = "convert_wait_done";
  return true;
}

bool readScratchpad(uint8_t* scratchpad, const size_t len) {
  if (scratchpad == nullptr || len == 0) {
    g_lastFailureStage = "read_bad_buffer";
    return false;
  }
  if (!resetPulse()) {
    g_lastFailureStage = "read_reset";
    return false;
  }
  writeByte(kCmdSkipRom);
  writeByte(kCmdReadScratchpad);
  for (size_t i = 0; i < len; ++i) {
    scratchpad[i] = readByte();
  }
  g_lastFailureStage = "scratchpad_read";
  return true;
}

void readRomDiagnostic() {
  for (size_t i = 0; i < sizeof(g_lastRom); ++i) {
    g_lastRom[i] = 0;
  }
  if (!resetPulse()) {
    g_lastFailureStage = "rom_reset";
    return;
  }
  writeByte(kCmdReadRom);
  for (size_t i = 0; i < sizeof(g_lastRom); ++i) {
    g_lastRom[i] = readByte();
  }
}

}  // namespace

namespace m601_temp {

bool begin() {
  configureBus();
  delay(10);

  uint8_t lastFailureFlags = TEMP_FLAG_BUS_ERROR;
  for (uint8_t attempt = 0; attempt < 3; ++attempt) {
    const bool idleHigh = readBusHigh();
    if (!idleHigh) {
      g_lastFailureStage = "begin_idle_low";
      lastFailureFlags = TEMP_FLAG_BUS_ERROR | TEMP_FLAG_IDLE_LOW;
      delay(20);
      continue;
    }

    if (resetPulse(kResetLowUs) || resetPulse(kResetLowUsLowVoltageFallback)) {
      readRomDiagnostic();
      g_lastFailureStage = "begin_ok";
      g_lastStatusFlags = TEMP_FLAG_PRESENCE_OK;
      return true;
    }
    g_lastFailureStage = "begin_no_presence";
    lastFailureFlags = TEMP_FLAG_BUS_ERROR | TEMP_FLAG_NO_PRESENCE;
    delay(20);
  }

  g_lastStatusFlags = lastFailureFlags;
  return false;
}

bool readSample(TemperatureSample& sample) {
  if (!startConversion()) {
    ++g_busFailCount;
    g_lastStatusFlags = TEMP_FLAG_BUS_ERROR;
    return false;
  }
  if (!waitForConversion()) {
    ++g_busFailCount;
    g_lastStatusFlags = TEMP_FLAG_PRESENCE_OK | TEMP_FLAG_BUS_ERROR;
    return false;
  }

  uint8_t scratchpad[9] = {};
  if (!readScratchpad(scratchpad, sizeof(scratchpad))) {
    ++g_busFailCount;
    g_lastStatusFlags = TEMP_FLAG_BUS_ERROR;
    return false;
  }
  for (size_t i = 0; i < sizeof(g_lastScratchpad); ++i) {
    g_lastScratchpad[i] = scratchpad[i];
  }

  const uint8_t crc = crc8Dallas(scratchpad, 8);
  g_lastCrcCalculated = crc;
  g_lastCrcRead = scratchpad[8];
  if (crc != scratchpad[8]) {
    ++g_crcFailCount;
    g_lastFailureStage = "crc";
    g_lastStatusFlags = TEMP_FLAG_PRESENCE_OK | TEMP_FLAG_CRC_ERROR;
    return false;
  }

  const uint8_t tempLsb = scratchpad[0];
  const uint8_t tempMsb = scratchpad[1];
  const uint16_t data = (static_cast<uint16_t>(tempMsb) << 8) | tempLsb;
  const int16_t raw = static_cast<int16_t>(data);

  sample.ts_us = time_sync::nowMicros();
  sample.raw = raw;
  sample.temp_c = (static_cast<float>(raw) / 256.0f) + 40.0f;
  sample.flags = TEMP_FLAG_CRC_OK | TEMP_FLAG_PRESENCE_OK;
  g_lastFailureStage = "ok";
  g_lastStatusFlags = sample.flags;
  return true;
}

uint8_t lastStatusFlags() { return g_lastStatusFlags; }

const char* lastFailureStage() { return g_lastFailureStage; }

uint8_t lastCrcCalculated() { return g_lastCrcCalculated; }

uint8_t lastCrcRead() { return g_lastCrcRead; }

void copyLastScratchpad(uint8_t* out, const size_t len) {
  if (out == nullptr) {
    return;
  }
  const size_t n = len < sizeof(g_lastScratchpad) ? len : sizeof(g_lastScratchpad);
  for (size_t i = 0; i < n; ++i) {
    out[i] = g_lastScratchpad[i];
  }
}

void copyLastRom(uint8_t* out, const size_t len) {
  if (out == nullptr) {
    return;
  }
  const size_t n = len < sizeof(g_lastRom) ? len : sizeof(g_lastRom);
  for (size_t i = 0; i < n; ++i) {
    out[i] = g_lastRom[i];
  }
}

uint32_t crcFailCount() { return g_crcFailCount; }

uint32_t busFailCount() { return g_busFailCount; }

}  // namespace m601_temp
