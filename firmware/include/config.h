#pragma once

#include <Arduino.h>

// ECG - AD8232
constexpr gpio_num_t ECG_ADC_PIN = GPIO_NUM_34;
constexpr gpio_num_t ECG_LOD_PLUS_PIN = GPIO_NUM_32;
constexpr gpio_num_t ECG_LOD_MINUS_PIN = GPIO_NUM_33;
constexpr uint32_t ECG_SAMPLE_RATE_HZ = 500;
constexpr uint32_t ECG_SAMPLE_PERIOD_US = 1000000UL / ECG_SAMPLE_RATE_HZ;

// MAX30102 - I2C
constexpr gpio_num_t PPG_I2C_SDA_PIN = GPIO_NUM_21;
constexpr gpio_num_t PPG_I2C_SCL_PIN = GPIO_NUM_22;
constexpr gpio_num_t PPG_INT_PIN = GPIO_NUM_4;
constexpr uint32_t PPG_SAMPLE_RATE_HZ = 200;
constexpr uint32_t PPG_SAMPLE_PERIOD_US = 1000000UL / PPG_SAMPLE_RATE_HZ;
constexpr uint32_t PPG_I2C_CLOCK_HZ = 400000;

// BMI160 - SPI
constexpr gpio_num_t BMI_SPI_SCK_PIN = GPIO_NUM_18;
constexpr gpio_num_t BMI_SPI_MISO_PIN = GPIO_NUM_19;
constexpr gpio_num_t BMI_SPI_MOSI_PIN = GPIO_NUM_23;
constexpr gpio_num_t BMI_SPI_CS_PIN = GPIO_NUM_5;
constexpr gpio_num_t BMI_INT1_PIN = GPIO_NUM_16;
constexpr gpio_num_t BMI_INT2_PIN = GPIO_NUM_17;
constexpr uint32_t BMI_SAMPLE_RATE_HZ = 200;
constexpr uint32_t BMI_SAMPLE_PERIOD_US = 1000000UL / BMI_SAMPLE_RATE_HZ;
constexpr uint32_t BMI_SPI_CLOCK_HZ = 1000000;

// M601 - 1-Wire digital temperature sensor
constexpr gpio_num_t M601_DQ_PIN = GPIO_NUM_14;
constexpr uint32_t M601_SAMPLE_RATE_HZ = 1;
constexpr uint32_t M601_SAMPLE_PERIOD_MS = 1000UL / M601_SAMPLE_RATE_HZ;
constexpr uint32_t M601_CONVERSION_TIMEOUT_MS = 30;

// Output mode switch
constexpr gpio_num_t OUTPUT_MODE_SWITCH_PIN = GPIO_NUM_27;
constexpr uint32_t OUTPUT_MODE_SWITCH_DEBOUNCE_MS = 50;

// Queues
constexpr uint32_t ECG_QUEUE_LEN = 1024;
constexpr uint32_t PPG_QUEUE_LEN = 512;
constexpr uint32_t IMU_QUEUE_LEN = 512;
constexpr uint32_t TEMP_QUEUE_LEN = 16;

// Task stack sizes
constexpr uint32_t ECG_TASK_STACK = 4096;
constexpr uint32_t PPG_TASK_STACK = 6144;
constexpr uint32_t IMU_TASK_STACK = 6144;
constexpr uint32_t TEMP_TASK_STACK = 4096;
constexpr uint32_t LOGGER_TASK_STACK = 6144;
constexpr uint32_t OUTPUT_MODE_TASK_STACK = 8192;

// Task priorities
constexpr UBaseType_t ECG_TASK_PRIORITY = 4;
constexpr UBaseType_t PPG_TASK_PRIORITY = 3;
constexpr UBaseType_t IMU_TASK_PRIORITY = 3;
constexpr UBaseType_t TEMP_TASK_PRIORITY = 2;
constexpr UBaseType_t LOGGER_TASK_PRIORITY = 2;  // packetizer/logger
constexpr UBaseType_t UART_TASK_PRIORITY = 1;
constexpr UBaseType_t MQTT_TASK_PRIORITY = 3;

// UART
constexpr uint32_t DEBUG_BAUDRATE = 921600;

// BLE (NimBLE)
constexpr uint32_t BLE_TASK_STACK = 6144;
constexpr UBaseType_t BLE_TASK_PRIORITY = 3;
constexpr uint32_t BLE_ECG_QUEUE_LEN = 2048;
constexpr uint32_t BLE_PPG_QUEUE_LEN = 1024;
constexpr uint32_t BLE_TEMP_QUEUE_LEN = 16;
constexpr uint16_t BLE_MTU_TARGET = 512;
constexpr uint16_t BLE_NOTIFY_PAYLOAD_FALLBACK = 20;
constexpr const char* BLE_SERVICE_UUID = "c0ad0001-8d2b-4d6f-9a1c-1c8a52f0a001";
constexpr const char* BLE_NOTIFY_CHAR_UUID = "c0ad1001-8d2b-4d6f-9a1c-1c8a52f0a001";
constexpr const char* BLE_CONTROL_CHAR_UUID = "c0ad1002-8d2b-4d6f-9a1c-1c8a52f0a001";
constexpr const char* BLE_DEVICE_NAME = "esp32-bio";

#ifndef ENABLE_WIFI_OUTPUT
#define ENABLE_WIFI_OUTPUT 1  // 1 = send via WiFi MQTT, 0 = disable WiFi output
#endif

#ifndef ENABLE_UART_OUTPUT
#define ENABLE_UART_OUTPUT 0  // 1 = send samples via UART, 0 = disable UART sample output
#endif

#ifndef ENABLE_BLE_OUTPUT
#define ENABLE_BLE_OUTPUT 1
  // 1 = send samples via BLE, 0 = disable BLE output
#endif

#ifndef ENABLE_SERIAL_LOGGER
#define ENABLE_SERIAL_LOGGER 0  // 1 = print text logs to serial, 0 = disable
#endif

#ifndef ENABLE_ECG_OUTPUT
#define ENABLE_ECG_OUTPUT 1
#endif

#ifndef ENABLE_PPG_OUTPUT
#define ENABLE_PPG_OUTPUT 1
#endif

#ifndef ENABLE_IMU_OUTPUT
#define ENABLE_IMU_OUTPUT 0
#endif

#ifndef ENABLE_TEMP_OUTPUT
#define ENABLE_TEMP_OUTPUT 1
#endif

// Logger format:
// 1 = compact CSV tags (E/P/I)
// 2 = binary frames
#ifndef LOGGER_OUTPUT_MODE
#define LOGGER_OUTPUT_MODE 2
#endif

#if (LOGGER_OUTPUT_MODE != 1) && (LOGGER_OUTPUT_MODE != 2)
#error "LOGGER_OUTPUT_MODE must be 1 (compact CSV) or 2 (binary frames)."
#endif

#ifndef ENABLE_TEXT_STATUS
#if LOGGER_OUTPUT_MODE == 2
#define ENABLE_TEXT_STATUS 0
#else
#define ENABLE_TEXT_STATUS 1
#endif
#endif

// Cloud connectivity (WiFi + MQTT)
#ifndef WIFI_SSID
#define WIFI_SSID "江寻"
#endif

#ifndef WIFI_PASSWORD
#define WIFI_PASSWORD "woshinibaba"
#endif

#ifndef MQTT_BROKER_HOST
#define MQTT_BROKER_HOST "182.254.220.56"
#endif

#ifndef MQTT_BROKER_PORT
#define MQTT_BROKER_PORT 1883
#endif

#ifndef MQTT_CLIENT_ID_PREFIX
#define MQTT_CLIENT_ID_PREFIX "esp32-bio"
#endif

#ifndef MQTT_TOPIC_ROOT
#define MQTT_TOPIC_ROOT "cardio"
#endif

#ifndef MQTT_TOPIC_DEVICE_ID
#define MQTT_TOPIC_DEVICE_ID "esp32-bio"
#endif

#ifndef MQTT_SESSION_ID
#define MQTT_SESSION_ID "debug-session"
#endif

constexpr uint32_t MQTT_PUBLISH_PERIOD_MS = 5000;
constexpr uint32_t WIFI_RETRY_INTERVAL_MS = 5000;
constexpr uint32_t MQTT_RETRY_INTERVAL_MS = 3000;

// MQTT payload mode:
// 0 = JSON payload only
// 1 = Binary payload only
// 2 = JSON + Binary (dual publish)
#ifndef MQTT_PAYLOAD_MODE
#define MQTT_PAYLOAD_MODE 1
#endif

#if (MQTT_PAYLOAD_MODE < 0) || (MQTT_PAYLOAD_MODE > 2)
#error "MQTT_PAYLOAD_MODE must be 0 (JSON), 1 (Binary), or 2 (Both)."
#endif

