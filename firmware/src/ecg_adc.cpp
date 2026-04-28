#include "ecg_adc.h"

#include "config.h"
#include "time_sync.h"

namespace {   //内部私有链接，只允许该cpp中访问，避免命名冲突

// 定时器 ISR 只置位标志，真正的 ADC 读取放到任务上下文中完成。
volatile uint32_t g_pendingEcgSamples = 0;  //待处理的样本数
hw_timer_t* g_ecgTimer = nullptr;   //定时器句柄
portMUX_TYPE g_ecgTimerMux = portMUX_INITIALIZER_UNLOCKED;  //FreeRTOS互斥锁，ISR和任务共享访问g_pendingEcgSamples，保护其原子性

constexpr uint8_t ECG_OVERSAMPLE_COUNT = 5;  //过采样次数
constexpr uint8_t ECG_SATURATION_RETRY_COUNT = 3;// ADC 饱和重试次数
constexpr uint16_t ECG_ADC_MIN_SATURATION = 8;// AD8232 输出中值附近约 2048，过低或过高都可能是饱和，经验值设定为 8 个 ADC 单位（约 3.9mV）以外即认为饱和
constexpr uint16_t ECG_ADC_MAX_SATURATION = 4087; //避免信号误判，且ADC满量程时线性度低

bool isSaturated(uint16_t value) {  //判断饱和与否
  return value <= ECG_ADC_MIN_SATURATION || value >= ECG_ADC_MAX_SATURATION;
}

uint16_t median5(uint16_t a,    //中值滤波，对5次连续采样结果取中位数，减少偶发的电磁干扰引起的异常值对数据质量的影响
                 uint16_t b,
                 uint16_t c,
                 uint16_t d,
                 uint16_t e) {
  uint16_t values[ECG_OVERSAMPLE_COUNT] = {a, b, c, d, e};
  for (uint8_t i = 1; i < ECG_OVERSAMPLE_COUNT; ++i) {
    const uint16_t key = values[i];
    int8_t j = static_cast<int8_t>(i) - 1;
    while (j >= 0 && values[j] > key) {
      values[j + 1] = values[j];
      --j;
    }
    values[j + 1] = key;    //进行排序（插入排序），最终结果是values数组从小到大排序，返回中间那个值即为中位数
  }
  return values[ECG_OVERSAMPLE_COUNT / 2];
}

uint16_t readEcgBurst() {
  return median5(analogRead(static_cast<uint8_t>(ECG_ADC_PIN)),  //Read只能读取8位，但我们之前设置了12位分辨率，因此需要读取5次取中值以获得更稳定的结果
                 analogRead(static_cast<uint8_t>(ECG_ADC_PIN)),
                 analogRead(static_cast<uint8_t>(ECG_ADC_PIN)),
                 analogRead(static_cast<uint8_t>(ECG_ADC_PIN)),
                 analogRead(static_cast<uint8_t>(ECG_ADC_PIN)));
}

void IRAM_ATTR onEcgTimer() { //定时器中断函数，每当定时器触发时调用，增加待处理样本计数
  portENTER_CRITICAL_ISR(&g_ecgTimerMux); //进入临界区
  ++g_pendingEcgSamples;    //只做计数，不把耗时的ADC读取（10-20us）放到ISR中
  portEXIT_CRITICAL_ISR(&g_ecgTimerMux);  //退出临界区
}

}  // namespace

namespace ecg_adc {

bool begin() {
  // ECG 使用 ADC1 的 GPIO34，保留原始 12 位 ADC 结果供后续滤波。
  analogReadResolution(12);   //分辨率设置
  analogSetPinAttenuation(static_cast<uint8_t>(ECG_ADC_PIN), ADC_11db);   //ADC引脚配置 衰减（0-3.6V符合要求范围）
  pinMode(static_cast<uint8_t>(ECG_LOD_PLUS_PIN), INPUT);   
  pinMode(static_cast<uint8_t>(ECG_LOD_MINUS_PIN), INPUT);
  return true;
}

void start() {
  if (g_ecgTimer != nullptr) {
    return;
  }

  // APB 80MHz / 80 = 1MHz，因此定时器计数单位为 1us。
  g_ecgTimer = timerBegin(0, 80, true); //选择定时器，80分频，向上计数
  timerAttachInterrupt(g_ecgTimer, &onEcgTimer, true);  //定时器中断配置边沿触发、中断函数
  timerAlarmWrite(g_ecgTimer, ECG_SAMPLE_PERIOD_US, true);  //定时器周期，自动重载
  timerAlarmEnable(g_ecgTimer);
}

bool sampleOnce(EcgSample& sample) {
  //1、检查是否采样请求，如果没有则直接返回，避免不必要的 ADC 读取和时间戳获取。
  bool shouldSample = false;

  portENTER_CRITICAL(&g_ecgTimerMux);  //进入临界区
  if (g_pendingEcgSamples > 0) {
    --g_pendingEcgSamples;
    shouldSample = true;
  }
  portEXIT_CRITICAL(&g_ecgTimerMux);

  if (!shouldSample) {
    return false;
  }

  // 在实际读取 ADC 后立即打统一微秒时间戳。2、采样
  uint16_t adcValue = readEcgBurst();
  //3、检查是否饱和、重试
  if (isSaturated(adcValue)) {
    for (uint8_t retry = 0; retry < ECG_SATURATION_RETRY_COUNT; ++retry) {
      const uint16_t retriedValue = readEcgBurst();
      adcValue = retriedValue;
      if (!isSaturated(retriedValue)) {
        break;
      }
    }
  }
  //4、填充样本结构体，准备入队
  sample.raw_adc = adcValue;
  sample.lead_off_plus = digitalRead(static_cast<uint8_t>(ECG_LOD_PLUS_PIN));
  sample.lead_off_minus = digitalRead(static_cast<uint8_t>(ECG_LOD_MINUS_PIN));
  sample.ts_us = time_sync::nowMicros();
  return true;
}

bool pushSample(QueueHandle_t queue, const EcgSample& sample) {
  // 使用非阻塞入队，避免高频采样任务因为队列满而卡住。
  return xQueueSend(queue, &sample, 0) == pdPASS;  //0表示等待时间为0，未入队返回errQUEUE_FULL，成功返回pdPASS
}

bool isrFlagSet() {   //查询待处理样本数，决定是否sampleonce
  return g_pendingEcgSamples > 0;
}

}  // namespace ecg_adc
