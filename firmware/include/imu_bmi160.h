#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "data_types.h"

namespace imu_bmi160 {

bool begin();
size_t service(QueueHandle_t queue);
bool hasPendingInterrupt();
uint8_t chipId();
uint8_t spiMode();
uint8_t errorReg();
uint8_t pmuStatus();
uint8_t statusReg();

}  // namespace imu_bmi160
