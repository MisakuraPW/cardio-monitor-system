#include "time_sync.h"

#include <esp_timer.h>

namespace time_sync {

// 返回 ESP32 系统统一微秒时间基准(有符号整型)，所有传感器都以它对齐。
uint64_t nowMicros() { return static_cast<uint64_t>(esp_timer_get_time()); } //C++类型强制转换更加安全

uint64_t backCalculateTimestamp(uint64_t readTsUs, uint32_t samplePeriodUs, //当前时间、采样周期
                                size_t totalSamples, size_t sampleIndex) {  //总样本数，索引
  if (totalSamples == 0 || sampleIndex >= totalSamples) {
    return readTsUs;
  }

  // 对 FIFO 批量读取场景做时间回推，越早采到的样本时间越靠前。
  const size_t samplesBehind = (totalSamples - 1U) - sampleIndex;
  return readTsUs - (static_cast<uint64_t>(samplesBehind) * samplePeriodUs);
}

}  // namespace time_sync
