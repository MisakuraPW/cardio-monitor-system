#pragma once

#include "data_types.h"

namespace ble_stream {

void begin();
void taskLoop();
bool enqueueEcg(const EcgSample& sample);
bool enqueuePpg(const PpgSample& sample);
bool enqueueImu(const ImuSample& sample);
bool enqueueTemperature(const TemperatureSample& sample);

}  // namespace ble_stream
