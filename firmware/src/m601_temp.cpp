#include "m601_temp.h"

#include "config.h"
#include "time_sync.h"

namespace {

constexpr uint8_t kCmdSkipRom = 0xCC;
constexpr uint8_t kCmdConvertT = 0x44;
constexpr uint8_t kCmdReadScratchpad = 0xBE;

constexpr uint8_t kFlagCrcOk = 0x01;
constexpr uint8_t kFlagPresenceOk = 0x02;

portMUX_TYPE g_oneWireMux = portMUX_INITIALIZER_UNLOCKED;
uint32_t g_crcFailCount = 0;
uint32_t g_busFailCount = 0;

void releaseBus() {
  pinMode(static_cast<uint8_t>(M601_DQ_PIN), INPUT);
}

void pullBusLow() {
  digitalWrite(static_cast<uint8_t>(M601_DQ_PIN), LOW);
  pinMode(static_cast<uint8_t>(M601_DQ_PIN), OUTPUT);
}

bool resetPulse() {
  portENTER_CRITICAL(&g_oneWireMux);
  pullBusLow();
  delayMicroseconds(500);
  releaseBus();
  delayMicroseconds(70);
  const bool present = (digitalRead(static_cast<uint8_t>(M601_DQ_PIN)) == LOW);
  delayMicroseconds(410);
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
  const uint32_t startMs = millis();
  while ((millis() - startMs) < M601_CONVERSION_TIMEOUT_MS) {
    if (readBit()) {
      return true;
    }
    delay(1);
  }
  return false;
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
  digitalWrite(static_cast<uint8_t>(M601_DQ_PIN), LOW);
  releaseBus();
  delay(5);
  return resetPulse();
}

bool readSample(TemperatureSample& sample) {
  if (!startConversion()) {
    ++g_busFailCount;
    return false;
  }
  if (!waitForConversion()) {
    ++g_busFailCount;
    return false;
  }

  uint8_t scratchpad[9] = {};
  if (!readScratchpad(scratchpad, sizeof(scratchpad))) {
    ++g_busFailCount;
    return false;
  }

  const uint8_t crc = crc8Dallas(scratchpad, 8);
  if (crc != scratchpad[8]) {
    ++g_crcFailCount;
    return false;
  }

  const uint8_t tempLsb = scratchpad[0];
  const uint8_t tempMsb = scratchpad[1];
  const uint16_t data = (static_cast<uint16_t>(tempMsb) << 8) | tempLsb;
  const int16_t raw = static_cast<int16_t>(data);

  sample.ts_us = time_sync::nowMicros();
  sample.raw = raw;
  sample.temp_c = (static_cast<float>(raw) / 256.0f) + 40.0f;
  sample.flags = kFlagCrcOk | kFlagPresenceOk;
  return true;
}

uint32_t crcFailCount() { return g_crcFailCount; }

uint32_t busFailCount() { return g_busFailCount; }

}  // namespace m601_temp
