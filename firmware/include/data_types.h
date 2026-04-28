#pragma once

#include <Arduino.h>

enum class SensorType : uint8_t {  //强枚举，避免隐式转换，底层类型为uint8_t节省内存
  Ecg = 0,
  Ppg = 1,
  Imu = 2,
};

struct EcgSample {
  uint64_t ts_us;  //时间戳，单位微秒，使用64位整数以避免溢出
  uint16_t raw_adc;   //原始ADC值，AD8232输出为10位分辨率，使用16位整数存储以节省空间
  bool lead_off_plus;   //正负导联脱落状态
  bool lead_off_minus;
};

struct PpgSample {
  uint64_t ts_us;
  uint32_t ir;  
  uint32_t red;
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
