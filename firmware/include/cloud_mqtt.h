#pragma once

#include "data_types.h"

namespace cloud_mqtt {

void begin();
void taskLoop();
bool enqueueEcg(const EcgSample& sample);
bool enqueuePpg(const PpgSample& sample);
bool enqueueImu(const ImuSample& sample);

}  // namespace cloud_mqtt
