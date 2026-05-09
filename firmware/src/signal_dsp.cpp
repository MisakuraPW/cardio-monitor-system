#include "signal_dsp.h"

#include <Arduino.h>
#include <math.h>
#include <string.h>

#include "config.h"

namespace signal_dsp {
namespace {

constexpr float kTwoPi = 6.28318530718f;
constexpr float kAdcMax = 4095.0f;
constexpr uint8_t kMaxNlmsTaps = 16;

struct OnePoleHighpass {
  float alpha = 0.0f;
  float previousInput = 0.0f;
  float previousOutput = 0.0f;

  void configure(float cutoffHz, float sampleRateHz) {
    const float dt = 1.0f / sampleRateHz;
    const float rc = 1.0f / (kTwoPi * max(0.01f, cutoffHz));
    alpha = rc / (rc + dt);
  }

  float process(float x) {
    const float y = alpha * (previousOutput + x - previousInput);
    previousInput = x;
    previousOutput = y;
    return y;
  }

  void reset() {
    previousInput = 0.0f;
    previousOutput = 0.0f;
  }
};

struct OnePoleLowpass {
  float alpha = 1.0f;
  float y = 0.0f;
  bool initialized = false;

  void configure(float cutoffHz, float sampleRateHz) {
    const float dt = 1.0f / sampleRateHz;
    const float rc = 1.0f / (kTwoPi * max(0.01f, cutoffHz));
    alpha = dt / (rc + dt);
  }

  float process(float x) {
    if (!initialized) {
      y = x;
      initialized = true;
      return y;
    }
    y += alpha * (x - y);
    return y;
  }

  void reset() {
    y = 0.0f;
    initialized = false;
  }
};

struct Biquad {
  float b0 = 1.0f;
  float b1 = 0.0f;
  float b2 = 0.0f;
  float a1 = 0.0f;
  float a2 = 0.0f;
  float x1 = 0.0f;
  float x2 = 0.0f;
  float y1 = 0.0f;
  float y2 = 0.0f;

  void configureNotch(float notchHz, float q, float sampleRateHz) {
    const float omega = kTwoPi * notchHz / sampleRateHz;
    const float sinw = sinf(omega);
    const float cosw = cosf(omega);
    const float alpha = sinw / (2.0f * max(0.1f, q));
    const float a0 = 1.0f + alpha;
    b0 = 1.0f / a0;
    b1 = (-2.0f * cosw) / a0;
    b2 = 1.0f / a0;
    a1 = (-2.0f * cosw) / a0;
    a2 = (1.0f - alpha) / a0;
  }

  float process(float x) {
    const float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
    x2 = x1;
    x1 = x;
    y2 = y1;
    y1 = y;
    return y;
  }

  void reset() {
    x1 = x2 = y1 = y2 = 0.0f;
  }
};

struct NlmsFilter {
  uint8_t taps = 8;
  float w[kMaxNlmsTaps] = {};
  float x[kMaxNlmsTaps] = {};

  void configure(uint8_t nextTaps) {
    taps = constrain(nextTaps, static_cast<uint8_t>(1), kMaxNlmsTaps);
  }

  float process(float reference, float desired, float step, float epsilon) {
    for (int i = taps - 1; i > 0; --i) {
      x[i] = x[i - 1];
    }
    x[0] = reference;

    float estimate = 0.0f;
    float norm = epsilon;
    for (uint8_t i = 0; i < taps; ++i) {
      estimate += w[i] * x[i];
      norm += x[i] * x[i];
    }

    const float error = desired - estimate;
    const float mu = step / norm;
    for (uint8_t i = 0; i < taps; ++i) {
      w[i] += mu * error * x[i];
    }
    return error;
  }

  void reset() {
    memset(w, 0, sizeof(w));
    memset(x, 0, sizeof(x));
  }
};

DspParams g_params = kDefaultDspParams;
uint32_t g_paramsVersion = 1;

OnePoleHighpass g_ecgHp;
OnePoleLowpass g_ecgLp;
Biquad g_ecgNotch;
OnePoleHighpass g_ppgIrHp;
OnePoleHighpass g_ppgRedHp;
OnePoleLowpass g_ppgIrLp;
OnePoleLowpass g_ppgRedLp;
OnePoleLowpass g_motionLp;
OnePoleHighpass g_motionHp;
NlmsFilter g_ppgIrNlms;
NlmsFilter g_ppgRedNlms;

float g_motionLevel = 0.0f;
float g_ecgQuality = 1.0f;
float g_ppgQuality = 1.0f;
float g_ecgHeartRateBpm = 0.0f;
float g_ppgPulseRateBpm = 0.0f;
float g_ecgPeakEnv = 0.0f;
float g_ppgPeakEnv = 0.0f;
uint64_t g_lastEcgPeakUs = 0;
uint64_t g_lastPpgPeakUs = 0;
float g_lastEcgFeature = 0.0f;
float g_lastPpgFeature = 0.0f;

uint16_t clampU16(float value) {
  if (value < 0.0f) {
    return 0;
  }
  if (value > 65535.0f) {
    return 65535;
  }
  return static_cast<uint16_t>(value + 0.5f);
}

uint32_t clampU32(float value) {
  if (value < 0.0f) {
    return 0;
  }
  if (value > 4294967040.0f) {
    return 4294967040UL;
  }
  return static_cast<uint32_t>(value + 0.5f);
}

float motionQualityScale() {
  const float threshold = max(1.0f, g_params.motionThreshold);
  if (g_motionLevel <= threshold) {
    return 1.0f;
  }
  const float excess = (g_motionLevel - threshold) / threshold;
  return constrain(1.0f - 0.55f * excess, 0.25f, 1.0f);
}

void configureFilters() {
  g_ecgHp.configure(g_params.ecgHighpassHz, ECG_SAMPLE_RATE_HZ);
  g_ecgLp.configure(g_params.ecgLowpassHz, ECG_SAMPLE_RATE_HZ);
  g_ecgNotch.configureNotch(g_params.ecgNotchHz, g_params.ecgNotchQ, ECG_SAMPLE_RATE_HZ);
  g_ppgIrHp.configure(g_params.ppgHighpassHz, PPG_SAMPLE_RATE_HZ);
  g_ppgRedHp.configure(g_params.ppgHighpassHz, PPG_SAMPLE_RATE_HZ);
  g_ppgIrLp.configure(g_params.ppgLowpassHz, PPG_SAMPLE_RATE_HZ);
  g_ppgRedLp.configure(g_params.ppgLowpassHz, PPG_SAMPLE_RATE_HZ);
  g_motionLp.configure(1.0f, BMI_SAMPLE_RATE_HZ);
  g_motionHp.configure(0.25f, BMI_SAMPLE_RATE_HZ);
  g_ppgIrNlms.configure(g_params.nlmsTaps);
  g_ppgRedNlms.configure(g_params.nlmsTaps);
}

void detectRate(float feature,
                float& env,
                float& lastFeature,
                uint64_t& lastPeakUs,
                float& bpm,
                uint64_t nowUs,
                float thresholdScale,
                uint32_t minIntervalMs,
                uint32_t maxIntervalMs) {
  env = max(env * 0.995f, fabsf(feature));
  const float threshold = env * thresholdScale;
  const bool risingPeak = lastFeature <= threshold && feature > threshold;
  lastFeature = feature;
  if (!risingPeak || env < 1.0f) {
    return;
  }
  if (lastPeakUs > 0) {
    const uint32_t intervalMs = static_cast<uint32_t>((nowUs - lastPeakUs) / 1000ULL);
    if (intervalMs >= minIntervalMs && intervalMs <= maxIntervalMs) {
      const float nextBpm = 60000.0f / intervalMs;
      bpm = bpm <= 0.0f ? nextBpm : (0.85f * bpm + 0.15f * nextBpm);
    }
  }
  lastPeakUs = nowUs;
}

}  // namespace

void begin() {
  configureFilters();
  reset();
}

void reset() {
  g_ecgHp.reset();
  g_ecgLp.reset();
  g_ecgNotch.reset();
  g_ppgIrHp.reset();
  g_ppgRedHp.reset();
  g_ppgIrLp.reset();
  g_ppgRedLp.reset();
  g_motionLp.reset();
  g_motionHp.reset();
  g_ppgIrNlms.reset();
  g_ppgRedNlms.reset();
  g_motionLevel = 0.0f;
  g_ecgQuality = 1.0f;
  g_ppgQuality = 1.0f;
  g_ecgHeartRateBpm = 0.0f;
  g_ppgPulseRateBpm = 0.0f;
  g_ecgPeakEnv = 0.0f;
  g_ppgPeakEnv = 0.0f;
  g_lastEcgPeakUs = 0;
  g_lastPpgPeakUs = 0;
  g_lastEcgFeature = 0.0f;
  g_lastPpgFeature = 0.0f;
}

void setEnabled(bool enabled) {
  g_params.enabled = enabled;
  ++g_paramsVersion;
}

void updateParams(const DspParams& params) {
  g_params = params;
  g_params.nlmsTaps = constrain(g_params.nlmsTaps, static_cast<uint8_t>(1), kMaxNlmsTaps);
  g_params.ppgSmoothingWindow = max(static_cast<uint8_t>(1), g_params.ppgSmoothingWindow);
  ++g_paramsVersion;
  configureFilters();
  reset();
}

DspParams params() { return g_params; }

DspMetrics metrics() {
  return DspMetrics{
    g_params.enabled,
    g_paramsVersion,
    g_motionLevel,
    g_ecgQuality,
    g_ppgQuality,
    g_ecgHeartRateBpm,
    g_ppgPulseRateBpm,
  };
}

void updateImu(const ImuSample& sample) {
  const float ax = static_cast<float>(sample.acc_x);
  const float ay = static_cast<float>(sample.acc_y);
  const float az = static_cast<float>(sample.acc_z);
  const float magnitude = sqrtf(ax * ax + ay * ay + az * az);
  const float motion = fabsf(g_motionHp.process(magnitude));
  g_motionLevel = g_motionLp.process(motion);
}

void processEcg(EcgSample& sample) {
  if (!g_params.enabled) {
    sample.filtered_adc = sample.raw_adc;
    sample.quality = 1.0f;
    sample.flags = 0;
    return;
  }

  float y = static_cast<float>(sample.raw_adc);
  y = g_ecgHp.process(y);
  if (g_params.ecgNotchEnabled) {
    y = g_ecgNotch.process(y);
  }
  y = g_ecgLp.process(y);
  const float centered = y;
  const float display = constrain(centered + 2048.0f, 0.0f, kAdcMax);
  sample.filtered_adc = clampU16(display);

  const bool leadOff = sample.lead_off_plus || sample.lead_off_minus;
  const float motionScale = motionQualityScale();
  sample.quality = leadOff ? 0.1f : motionScale;
  sample.flags = leadOff ? 0x01 : 0x00;
  if (g_motionLevel > g_params.motionThreshold) {
    sample.flags |= 0x02;
  }

  if (!leadOff) {
    const float diff = centered - g_lastEcgFeature;
    detectRate(diff * diff,
               g_ecgPeakEnv,
               g_lastEcgFeature,
               g_lastEcgPeakUs,
               g_ecgHeartRateBpm,
               sample.ts_us,
               g_params.ecgPeakThreshold,
               280,
               1800);
  }
  g_ecgQuality = sample.quality;
}

void processPpg(PpgSample& sample) {
  if (!g_params.enabled) {
    sample.filtered_ir = sample.ir;
    sample.filtered_red = sample.red;
    sample.quality = 1.0f;
    sample.flags = 0;
    return;
  }

  float ir = g_ppgIrLp.process(g_ppgIrHp.process(static_cast<float>(sample.ir)));
  float red = g_ppgRedLp.process(g_ppgRedHp.process(static_cast<float>(sample.red)));
  if (g_params.ppgNlmsEnabled) {
    const float reference = g_motionLevel / max(1.0f, g_params.motionThreshold);
    ir = g_ppgIrNlms.process(reference, ir, g_params.nlmsStep, g_params.nlmsEpsilon);
    red = g_ppgRedNlms.process(reference, red, g_params.nlmsStep, g_params.nlmsEpsilon);
  }

  sample.filtered_ir = clampU32(ir + 50000.0f);
  sample.filtered_red = clampU32(red + 50000.0f);
  sample.quality = motionQualityScale();
  sample.flags = g_motionLevel > g_params.motionThreshold ? 0x02 : 0x00;

  detectRate(ir,
             g_ppgPeakEnv,
             g_lastPpgFeature,
             g_lastPpgPeakUs,
             g_ppgPulseRateBpm,
             sample.ts_us,
             0.35f,
             320,
             2000);
  g_ppgQuality = sample.quality;
}

}  // namespace signal_dsp
