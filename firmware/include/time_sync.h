#pragma once

#include <Arduino.h>

namespace time_sync {

uint64_t nowMicros();
uint64_t backCalculateTimestamp(uint64_t readTsUs, uint32_t samplePeriodUs,
                                size_t totalSamples, size_t sampleIndex);

}  // namespace time_sync
