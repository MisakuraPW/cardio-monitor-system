#pragma once

#include <Arduino.h>

#include "data_types.h"

namespace m601_temp {

constexpr uint8_t TEMP_FLAG_CRC_OK = 0x01;
constexpr uint8_t TEMP_FLAG_PRESENCE_OK = 0x02;
constexpr uint8_t TEMP_FLAG_STALE = 0x04;
constexpr uint8_t TEMP_FLAG_BUS_ERROR = 0x08;
constexpr uint8_t TEMP_FLAG_CRC_ERROR = 0x10;
constexpr uint8_t TEMP_FLAG_IDLE_LOW = 0x20;
constexpr uint8_t TEMP_FLAG_NO_PRESENCE = 0x40;

bool begin();
bool readSample(TemperatureSample& sample);
uint8_t lastStatusFlags();
const char* lastFailureStage();
uint8_t lastCrcCalculated();
uint8_t lastCrcRead();
void copyLastScratchpad(uint8_t* out, size_t len);
void copyLastRom(uint8_t* out, size_t len);
uint32_t crcFailCount();
uint32_t busFailCount();

}  // namespace m601_temp
