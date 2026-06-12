#include "m601_temp.h"

#include "config.h"
#include "time_sync.h"

namespace {

constexpr uint8_t kCmdSkipRom = 0xCC;
constexpr uint8_t kCmdConvertT = 0x44;
constexpr uint8_t kCmdReadScratchpad = 0xBE;
constexpr uint16_t kResetLowUs = 960;
constexpr uint16_t kResetLowUsLowVoltageFallback = 2000;

portMUX_TYPE g_oneWireMux = portMUX_INITIALIZER_UNLOCKED;
uint32_t g_crcFailCount = 0;
uint32_t g_busFailCount = 0;
uint8_t g_lastStatusFlags = 0;

void releaseBus() {
  digitalWrite(static_cast<uint8_t>(M601_DQ_PIN), HIGH);
  pinMode(static_cast<uint8_t>(M601_DQ_PIN), INPUT_PULLUP);
}

void pullBusLow() {
  digitalWrite(static_cast<uint8_t>(M601_DQ_PIN), LOW);
  pinMode(static_cast<uint8_t>(M601_DQ_PIN), OUTPUT);
}

bool resetPulse(const uint16_t resetLowUs = kResetLowUs) {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  delayMicroseconds(resetLowUs);
  releaseBus();

  bool present = false;
  delayMicroseconds(15);
  for (uint8_t i = 0; i < 48; ++i) {
    if (digitalRead(static_cast<uint8_t>(M601_DQ_PIN)) == LOW) {
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
    delayMicroseconds(5);
    releaseBus();
    delayMicroseconds(60);
  } else {
    delayMicroseconds(60);
    releaseBus();
    delayMicroseconds(5);
  }
  portEXIT_CRITICAL(&g_oneWireMux);
}

bool readBit() {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  delayMicroseconds(2);
  releaseBus();
  delayMicroseconds(12);
  const bool value = (digitalRead(static_cast<uint8_t>(M601_DQ_PIN)) == HIGH);
  delayMicroseconds(50);
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
    return false;
  }
  writeByte(kCmdSkipRom);
  writeByte(kCmdConvertT);
  return true;
}

bool waitForConversion() {
  delay(M601_CONVERSION_TIMEOUT_MS);
  return true;
}

bool readScratchpad(uint8_t* scratchpad, const size_t len) {
  if (scratchpad == nullptr || len == 0) {
    return false;
  }
  if (!resetPulse()) {
    return false;
  }
  writeByte(kCmdSkipRom);
  writeByte(kCmdReadScratchpad);
  for (size_t i = 0; i < len; ++i) {
    scratchpad[i] = readByte();
  }
  return true;
}

}  // namespace

namespace m601_temp {

bool begin() {
  releaseBus();
  delay(10);

  uint8_t lastFailureFlags = TEMP_FLAG_BUS_ERROR;
  for (uint8_t attempt = 0; attempt < 3; ++attempt) {
    const bool idleHigh = digitalRead(static_cast<uint8_t>(M601_DQ_PIN)) == HIGH;
    if (!idleHigh) {
      lastFailureFlags = TEMP_FLAG_BUS_ERROR | TEMP_FLAG_IDLE_LOW;
      delay(20);
      continue;
    }

    if (resetPulse(kResetLowUs) || resetPulse(kResetLowUsLowVoltageFallback)) {
      g_lastStatusFlags = TEMP_FLAG_PRESENCE_OK;
      return true;
    }
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

  const uint8_t crc = crc8Dallas(scratchpad, 8);
  if (crc != scratchpad[8]) {
    ++g_crcFailCount;
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
  g_lastStatusFlags = sample.flags;
  return true;
}

uint8_t lastStatusFlags() { return g_lastStatusFlags; }

uint32_t crcFailCount() { return g_crcFailCount; }

uint32_t busFailCount() { return g_busFailCount; }

}  // namespace m601_temp
