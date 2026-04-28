#include "data_logger.h"

#include <stdint.h>

#include "config.h"

namespace {

#if LOGGER_OUTPUT_MODE == 2
constexpr uint8_t kSof1 = 0xA5;
constexpr uint8_t kSof2 = 0x5A;

#pragma pack(push, 1)
struct EcgPayloadBin {
  uint64_t ts_us;
  uint16_t raw_adc;
  uint8_t lead_off_plus;
  uint8_t lead_off_minus;
};

struct PpgPayloadBin {
  uint64_t ts_us;
  uint32_t ir;
  uint32_t red;
};

struct ImuPayloadBin {
  uint64_t ts_us;
  int16_t acc_x;
  int16_t acc_y;
  int16_t acc_z;
  int16_t gyr_x;
  int16_t gyr_y;
  int16_t gyr_z;
};
#pragma pack(pop)

uint8_t checksum8(const uint8_t type, const uint8_t len, const uint8_t* payload) {
  uint8_t sum = type ^ len;
  for (uint8_t i = 0; i < len; ++i) {
    sum ^= payload[i];
  }
  return sum;
}

void writeBinaryFrame(const uint8_t type, const void* payload, const uint8_t len) {
  const uint8_t* bytes = static_cast<const uint8_t*>(payload);
  const uint8_t header[4] = {kSof1, kSof2, type, len};
  const uint8_t cs = checksum8(type, len, bytes);
  Serial.write(header, sizeof(header));
  Serial.write(bytes, len);
  Serial.write(cs);
}
#endif

}  // namespace

namespace data_logger {

void begin(uint32_t baudrate) {
#if ENABLE_SERIAL_LOGGER
  Serial.begin(baudrate);
  delay(50);
#else
  (void)baudrate;
#endif
}

void logCsvHeader() {
#if ENABLE_SERIAL_LOGGER
#if LOGGER_OUTPUT_MODE == 0
  Serial.println(F("# type,ts_us,data..."));
#elif LOGGER_OUTPUT_MODE == 1
  Serial.println(F("# t,ts_us,data..."));
#else
  // Binary mode: no text header.
#endif
#endif
}

void logEcg(const EcgSample& sample) {
#if ENABLE_SERIAL_LOGGER && ENABLE_ECG_OUTPUT
#if LOGGER_OUTPUT_MODE == 0
  Serial.printf("ECG,%llu,%u,%u,%u\n", sample.ts_us, sample.raw_adc,
                sample.lead_off_plus ? 1 : 0, sample.lead_off_minus ? 1 : 0);
#elif LOGGER_OUTPUT_MODE == 1
  Serial.printf("E,%llu,%u,%u,%u\n", sample.ts_us, sample.raw_adc,
                sample.lead_off_plus ? 1 : 0, sample.lead_off_minus ? 1 : 0);
#else
  EcgPayloadBin payload{sample.ts_us, sample.raw_adc,
                        static_cast<uint8_t>(sample.lead_off_plus ? 1 : 0),
                        static_cast<uint8_t>(sample.lead_off_minus ? 1 : 0)};
  writeBinaryFrame('E', &payload, static_cast<uint8_t>(sizeof(payload)));
#endif
#else
  (void)sample;
#endif
}

void logPpg(const PpgSample& sample) {
#if ENABLE_SERIAL_LOGGER && ENABLE_PPG_OUTPUT
#if LOGGER_OUTPUT_MODE == 0
  Serial.printf("PPG,%llu,%lu,%lu\n", sample.ts_us,
                static_cast<unsigned long>(sample.ir),
                static_cast<unsigned long>(sample.red));
#elif LOGGER_OUTPUT_MODE == 1
  Serial.printf("P,%llu,%lu,%lu\n", sample.ts_us,
                static_cast<unsigned long>(sample.ir),
                static_cast<unsigned long>(sample.red));
#else
  PpgPayloadBin payload{sample.ts_us, sample.ir, sample.red};
  writeBinaryFrame('P', &payload, static_cast<uint8_t>(sizeof(payload)));
#endif
#else
  (void)sample;
#endif
}

void logImu(const ImuSample& sample) {
#if ENABLE_SERIAL_LOGGER && ENABLE_IMU_OUTPUT
#if LOGGER_OUTPUT_MODE == 0
  Serial.printf("IMU,%llu,%d,%d,%d,%d,%d,%d\n", sample.ts_us, sample.acc_x,
                sample.acc_y, sample.acc_z, sample.gyr_x, sample.gyr_y,
                sample.gyr_z);
#elif LOGGER_OUTPUT_MODE == 1
  Serial.printf("I,%llu,%d,%d,%d,%d,%d,%d\n", sample.ts_us, sample.acc_x,
                sample.acc_y, sample.acc_z, sample.gyr_x, sample.gyr_y,
                sample.gyr_z);
#else
  ImuPayloadBin payload{sample.ts_us, sample.acc_x, sample.acc_y, sample.acc_z,
                        sample.gyr_x, sample.gyr_y, sample.gyr_z};
  writeBinaryFrame('I', &payload, static_cast<uint8_t>(sizeof(payload)));
#endif
#else
  (void)sample;
#endif
}

void logStatus(const __FlashStringHelper* message) {
#if ENABLE_SERIAL_LOGGER && ENABLE_TEXT_STATUS
  Serial.println(message);
#else
  (void)message;
#endif
}

void logStatus(const char* message) {
#if ENABLE_SERIAL_LOGGER && ENABLE_TEXT_STATUS
  Serial.println(message);
#else
  (void)message;
#endif
}

}  // namespace data_logger
