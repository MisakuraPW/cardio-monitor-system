#pragma once

#include <Arduino.h>

enum class SensorType : uint8_t {
  Ecg = 0,
  Ppg = 1,
  Imu = 2,
  Temperature = 3,
};

struct EcgSample {
  uint64_t ts_us;
  uint16_t raw_adc;
  bool lead_off_plus;
  bool lead_off_minus;
  uint16_t filtered_adc;
  float quality;
  uint8_t flags;
};

struct PpgSample {
  uint64_t ts_us;
  uint32_t ir;
  uint32_t red;
  uint32_t filtered_ir;
  uint32_t filtered_red;
  float quality;
  uint8_t flags;
};

struct ImuSample {
  uint64_t ts_us;
  int16_t acc_x;
  int16_t acc_y;
  int16_t acc_z;
  int16_t gyr_x;
  int16_t gyr_y;
  int16_t gyr_z;
};

struct TemperatureSample {
  uint64_t ts_us;
  int16_t raw;
  float temp_c;
  uint8_t flags;
};
