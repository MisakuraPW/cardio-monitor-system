#include "imu_bmi160.h"

#include <SPI.h>

#include "config.h"
#include "time_sync.h"

namespace {

SPIClass g_bmiSpi(VSPI);
volatile bool g_imuInterruptFlag = false;
bool g_imuInitialized = false;
uint8_t g_chipId = 0x00;
uint8_t g_spiMode = SPI_MODE0;
uint8_t g_errorReg = 0x00;
uint8_t g_pmuStatus = 0x00;
uint8_t g_statusReg = 0x00;

constexpr uint8_t BMI160_REG_CHIP_ID = 0x00;
constexpr uint8_t BMI160_REG_ERR = 0x02;
constexpr uint8_t BMI160_REG_PMU_STATUS = 0x03;
constexpr uint8_t BMI160_REG_DATA_START = 0x0C;
constexpr uint8_t BMI160_REG_STATUS = 0x1B;
constexpr uint8_t BMI160_REG_ACC_CONF = 0x40;
constexpr uint8_t BMI160_REG_ACC_RANGE = 0x41;
constexpr uint8_t BMI160_REG_GYR_CONF = 0x42;
constexpr uint8_t BMI160_REG_GYR_RANGE = 0x43;
constexpr uint8_t BMI160_REG_INT_EN_1 = 0x51;
constexpr uint8_t BMI160_REG_INT_OUT_CTRL = 0x53;
constexpr uint8_t BMI160_REG_INT_LATCH = 0x54;
constexpr uint8_t BMI160_REG_INT_MAP_1 = 0x56;
constexpr uint8_t BMI160_REG_IF_CONF = 0x6B;
constexpr uint8_t BMI160_REG_SPI_COMM_TEST = 0x7F;
constexpr uint8_t BMI160_REG_CMD = 0x7E;

constexpr uint8_t BMI160_CHIP_ID_EXPECTED = 0xD1;
constexpr uint8_t BMI160_CMD_SOFT_RESET = 0xB6;
constexpr uint8_t BMI160_CMD_ACC_NORMAL = 0x11;
constexpr uint8_t BMI160_CMD_GYR_NORMAL = 0x15;

SPISettings makeSpiSettings() {
  return SPISettings(BMI_SPI_CLOCK_HZ, MSBFIRST, g_spiMode);
}

void IRAM_ATTR onImuInterrupt() { g_imuInterruptFlag = true; }

void spiBegin() {
  g_bmiSpi.beginTransaction(makeSpiSettings());
  digitalWrite(static_cast<uint8_t>(BMI_SPI_CS_PIN), LOW);
}

void spiEnd() {
  digitalWrite(static_cast<uint8_t>(BMI_SPI_CS_PIN), HIGH);
  g_bmiSpi.endTransaction();
}

void writeRegister(uint8_t reg, uint8_t value) {
  spiBegin();
  g_bmiSpi.transfer(reg & 0x7F);
  g_bmiSpi.transfer(value);
  spiEnd();
  delayMicroseconds(3);
}

uint8_t readRegister(uint8_t reg) {
  spiBegin();
  g_bmiSpi.transfer(reg | 0x80);
  const uint8_t value = g_bmiSpi.transfer(0x00);
  spiEnd();
  return value;
}

void readRegisters(uint8_t reg, uint8_t* buffer, size_t length) {
  spiBegin();
  g_bmiSpi.transfer(reg | 0x80);
  for (size_t i = 0; i < length; ++i) {
    buffer[i] = g_bmiSpi.transfer(0x00);
  }
  spiEnd();
}

uint8_t readRegisterWithMode(uint8_t reg, uint8_t spiMode) {
  g_spiMode = spiMode;
  spiBegin();
  g_bmiSpi.transfer(reg | 0x80);
  const uint8_t value = g_bmiSpi.transfer(0x00);
  spiEnd();
  return value;
}

void activatePrimarySpiInterface() {
  digitalWrite(static_cast<uint8_t>(BMI_SPI_CS_PIN), LOW);
  delayMicroseconds(5);
  digitalWrite(static_cast<uint8_t>(BMI_SPI_CS_PIN), HIGH);
  delayMicroseconds(5);
  (void)readRegisterWithMode(BMI160_REG_SPI_COMM_TEST, g_spiMode);
}

bool probeChipId(uint8_t& chipIdOut) {
  const uint8_t modes[2] = {SPI_MODE0, SPI_MODE3};

  for (uint8_t mode : modes) {
    g_spiMode = mode;
    activatePrimarySpiInterface();
    const uint8_t id = readRegisterWithMode(BMI160_REG_CHIP_ID, mode);
    if (id == BMI160_CHIP_ID_EXPECTED) {
      chipIdOut = id;
      return true;
    }
    delay(2);
  }

  chipIdOut = 0x00;
  return false;
}

bool configureSensor() {
  writeRegister(BMI160_REG_CMD, BMI160_CMD_SOFT_RESET);
  delay(100);

  // Bring up accel/gyro with retries because command execution may be delayed.
  bool accReady = false;
  bool gyrReady = false;
  for (int attempt = 0; attempt < 3; ++attempt) {
    writeRegister(BMI160_REG_CMD, BMI160_CMD_ACC_NORMAL);
    delay(30);
    writeRegister(BMI160_REG_CMD, BMI160_CMD_GYR_NORMAL);
    delay(80);

    g_pmuStatus = readRegister(BMI160_REG_PMU_STATUS);
    accReady = ((g_pmuStatus >> 4) & 0x03U) == 0x01U;
    gyrReady = ((g_pmuStatus >> 2) & 0x03U) == 0x01U;
    if (accReady && gyrReady) {
      break;
    }
  }

  // ODR = 200Hz, normal bandwidth for both accel and gyro.
  writeRegister(BMI160_REG_ACC_CONF, 0x29);
  writeRegister(BMI160_REG_GYR_CONF, 0x29);
  writeRegister(BMI160_REG_ACC_RANGE, 0x08);  // +/-8g
  writeRegister(BMI160_REG_GYR_RANGE, 0x00);  // +/-2000 dps
  writeRegister(BMI160_REG_IF_CONF, 0x00);    // 4-wire SPI

  // Map data-ready interrupt to INT1 pin.
  writeRegister(BMI160_REG_INT_EN_1, 0x10);
  writeRegister(BMI160_REG_INT_OUT_CTRL, 0x0A);
  writeRegister(BMI160_REG_INT_LATCH, 0x00);
  writeRegister(BMI160_REG_INT_MAP_1, 0x80);

  g_pmuStatus = readRegister(BMI160_REG_PMU_STATUS);
  g_errorReg = readRegister(BMI160_REG_ERR);
  g_statusReg = readRegister(BMI160_REG_STATUS);

  accReady = ((g_pmuStatus >> 4) & 0x03U) == 0x01U;
  gyrReady = ((g_pmuStatus >> 2) & 0x03U) == 0x01U;
  return accReady && gyrReady;
}

bool readImuSample(ImuSample& sample) {
  uint8_t raw[12] = {};
  readRegisters(BMI160_REG_DATA_START, raw, sizeof(raw));

  sample.gyr_x = static_cast<int16_t>((raw[1] << 8) | raw[0]);
  sample.gyr_y = static_cast<int16_t>((raw[3] << 8) | raw[2]);
  sample.gyr_z = static_cast<int16_t>((raw[5] << 8) | raw[4]);
  sample.acc_x = static_cast<int16_t>((raw[7] << 8) | raw[6]);
  sample.acc_y = static_cast<int16_t>((raw[9] << 8) | raw[8]);
  sample.acc_z = static_cast<int16_t>((raw[11] << 8) | raw[10]);
  sample.ts_us = time_sync::nowMicros();
  return true;
}

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

namespace imu_bmi160 {

bool begin() {
  g_imuInitialized = false;
  g_imuInterruptFlag = false;
  g_chipId = 0x00;
  g_errorReg = 0x00;
  g_pmuStatus = 0x00;
  g_statusReg = 0x00;

  pinMode(static_cast<uint8_t>(BMI_SPI_CS_PIN), OUTPUT);
  digitalWrite(static_cast<uint8_t>(BMI_SPI_CS_PIN), HIGH);
  pinMode(static_cast<uint8_t>(BMI_INT1_PIN), INPUT_PULLUP);

  g_bmiSpi.begin(static_cast<uint8_t>(BMI_SPI_SCK_PIN),
                 static_cast<uint8_t>(BMI_SPI_MISO_PIN),
                 static_cast<uint8_t>(BMI_SPI_MOSI_PIN),
                 static_cast<uint8_t>(BMI_SPI_CS_PIN));

  attachInterrupt(digitalPinToInterrupt(static_cast<uint8_t>(BMI_INT1_PIN)),
                  onImuInterrupt, RISING);

  const bool probeOk = probeChipId(g_chipId);
  if (!probeOk || g_chipId != BMI160_CHIP_ID_EXPECTED) {
    return false;
  }

  g_imuInitialized = configureSensor();
  if (!g_imuInitialized) {
    g_errorReg = readRegister(BMI160_REG_ERR);
    g_pmuStatus = readRegister(BMI160_REG_PMU_STATUS);
    g_statusReg = readRegister(BMI160_REG_STATUS);
  }
  return g_imuInitialized;
}

size_t service(QueueHandle_t queue) {
  if (!g_imuInitialized) {
    return 0;
  }

  ImuSample sample{};
  if (!readImuSample(sample)) {
    g_imuInterruptFlag = false;
    return 0;
  }

  g_imuInterruptFlag = false;
  return pushDroppingOldest(queue, sample) ? 1U : 0U;
}

bool hasPendingInterrupt() { return g_imuInterruptFlag; }

uint8_t chipId() { return g_chipId; }
uint8_t spiMode() { return g_spiMode; }
uint8_t errorReg() { return g_errorReg; }
uint8_t pmuStatus() { return g_pmuStatus; }
uint8_t statusReg() { return g_statusReg; }

}  // namespace imu_bmi160

