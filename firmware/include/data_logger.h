#pragma once

#include <Arduino.h>

#include "data_types.h"

namespace data_logger {

void begin(uint32_t baudrate);
void logCsvHeader();
void logEcg(const EcgSample& sample);
void logPpg(const PpgSample& sample);
void logImu(const ImuSample& sample);
void logTemperature(const TemperatureSample& sample);
void logStatus(const __FlashStringHelper* message);
void logStatus(const char* message);

}  // namespace data_logger
