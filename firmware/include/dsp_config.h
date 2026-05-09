#pragma once

#include <Arduino.h>

namespace signal_dsp {

struct DspParams {
  bool enabled = true;
  bool ecgNotchEnabled = true;
  bool ppgNlmsEnabled = true;
  float ecgHighpassHz = 0.5f;
  float ecgLowpassHz = 38.0f;
  float ecgNotchHz = 50.0f;
  float ecgNotchQ = 30.0f;
  float ecgPeakThreshold = 0.22f;
  float ppgHighpassHz = 0.35f;
  float ppgLowpassHz = 7.0f;
  uint8_t ppgSmoothingWindow = 5;
  uint8_t nlmsTaps = 8;
  float nlmsStep = 0.02f;
  float nlmsEpsilon = 0.001f;
  float motionThreshold = 650.0f;
};

const DspParams kDefaultDspParams{};

}  // namespace signal_dsp
