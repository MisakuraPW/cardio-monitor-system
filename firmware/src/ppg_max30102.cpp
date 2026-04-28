#include "ppg_max30102.h"

#include <MAX30105.h>
#include <Wire.h>

#include "config.h"
#include "time_sync.h"

namespace {

MAX30105 g_ppgSensor;
volatile bool g_ppgInterruptFlag = false;
bool g_ppgInitialized = false;

void IRAM_ATTR onPpgInterrupt() { g_ppgInterruptFlag = true; }

}  // namespace

template <typename T>
bool pushDroppingOldest(QueueHandle_t queue, const T& sample) {
  if (queue == nullptr) {
    return false;
  }

  if (xQueueSend(queue, &sample, 0) == pdPASS) {
    return true;
  }

  T oldSample{};
  (void)xQueueReceive(queue, &oldSample, 0);
  return xQueueSend(queue, &sample, 0) == pdPASS;
}

namespace ppg_max30102 {

bool begin() {
  g_ppgInitialized = false;
  g_ppgInterruptFlag = false;

  Wire.begin(static_cast<uint8_t>(PPG_I2C_SDA_PIN),
             static_cast<uint8_t>(PPG_I2C_SCL_PIN), PPG_I2C_CLOCK_HZ);
  Wire.setTimeOut(3);
  pinMode(static_cast<uint8_t>(PPG_INT_PIN), INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(static_cast<uint8_t>(PPG_INT_PIN)),
                  onPpgInterrupt, FALLING);

  if (!g_ppgSensor.begin(Wire, PPG_I2C_CLOCK_HZ)) {
    return false;
  }

  const byte ledBrightness = 0x1F;
  const byte sampleAverage = 1;
  const byte ledMode = 2;
  const int sampleRate = 200;
  const int pulseWidth = 411;
  const int adcRange = 4096;

  g_ppgSensor.setup(ledBrightness, sampleAverage, ledMode, sampleRate,
                    pulseWidth, adcRange);

  // Use both data-ready and almost-full to improve interrupt robustness.
  g_ppgSensor.setFIFOAlmostFull(0x0F);
  g_ppgSensor.enableAFULL();
  g_ppgSensor.disableALCOVF();
  g_ppgSensor.disablePROXINT();
  g_ppgSensor.disableDIETEMPRDY();
  g_ppgSensor.enableDATARDY();
  g_ppgSensor.enableFIFORollover();
  g_ppgSensor.clearFIFO();
  (void)g_ppgSensor.getINT1();
  (void)g_ppgSensor.getINT2();

  g_ppgInitialized = true;
  return true;
}

size_t service(QueueHandle_t queue) {
  if (!g_ppgInitialized) {
    return 0;
  }

  size_t pushedTotal = 0;
  for (;;) {
    g_ppgSensor.check();
    const int available = g_ppgSensor.available();
    if (available <= 0) {
      break;
    }

    const uint64_t readTsUs = time_sync::nowMicros();
    for (int i = 0; i < available; ++i) {
      PpgSample sample{};
      sample.red = g_ppgSensor.getFIFORed();
      sample.ir = g_ppgSensor.getFIFOIR();
      sample.ts_us = time_sync::backCalculateTimestamp(
          readTsUs, PPG_SAMPLE_PERIOD_US, static_cast<size_t>(available),
          static_cast<size_t>(i));

      if (pushDroppingOldest(queue, sample)) {
        ++pushedTotal;
      }
      g_ppgSensor.nextSample();
    }
  }

  (void)g_ppgSensor.getINT1();
  (void)g_ppgSensor.getINT2();
  g_ppgInterruptFlag = false;
  return pushedTotal;
}

bool hasPendingInterrupt() { return g_ppgInterruptFlag; }

}  // namespace ppg_max30102

