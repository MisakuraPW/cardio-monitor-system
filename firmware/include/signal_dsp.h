#pragma once

#include "data_types.h"
#include "dsp_config.h"

namespace signal_dsp {

struct DspMetrics {
  bool enabled;
  uint32_t paramsVersion;
  float motionLevel;
  float ecgQuality;
  float ppgQuality;
  float ecgHeartRateBpm;
  float ppgPulseRateBpm;
};

void begin();
void reset();
void setEnabled(bool enabled);
void updateParams(const DspParams& params);
DspParams params();
DspMetrics metrics();

void updateImu(const ImuSample& sample);
void processEcg(EcgSample& sample);
void processPpg(PpgSample& sample);

}  // namespace signal_dsp
