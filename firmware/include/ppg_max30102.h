#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "data_types.h"

namespace ppg_max30102 {

bool begin();
size_t service(QueueHandle_t queue);
bool hasPendingInterrupt();

}  // namespace ppg_max30102

