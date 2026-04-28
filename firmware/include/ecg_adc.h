#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "data_types.h"

namespace ecg_adc {

bool begin();
void start();
bool sampleOnce(EcgSample& sample);
bool pushSample(QueueHandle_t queue, const EcgSample& sample);
bool isrFlagSet();

}  // namespace ecg_adc
