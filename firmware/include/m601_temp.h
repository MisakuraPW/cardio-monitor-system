#pragma once

#include <Arduino.h>

#include "data_types.h"

namespace m601_temp {

bool begin();
bool readSample(TemperatureSample& sample);
uint32_t crcFailCount();
uint32_t busFailCount();

}  // namespace m601_temp
