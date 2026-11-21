// Real-time-safe loudness DSP kernel (ITU-R BS.1770-5 measurement front end).
//
// Shared by the analysis plug-in's render thread and the Swift side (tests, fake plug-in).
// Every function that runs on the render thread (lk_process_*, lk_*_ring_push/write) does no
// allocation, takes no locks and makes no system calls. All memory is supplied by the caller
// once, at setup time: ask for the size with lk_*_bytes(), allocate it (16-byte aligned), then
// call lk_*_init() on it.
//
// What the kernel does per channel: two-stage K-weighting (BS.1770-5 Annex 1, coefficients
// derived for any sample rate), sum of squares over 100 ms sub-blocks, sample peak and true
// peak (BS.1770-5 Annex 2: 4x oversampling below 96 kHz, 2x below 192 kHz, none from 192 kHz).
// Every completed sub-block becomes one lk_subblock record pushed into a single-producer /
// single-consumer ring that a background thread drains. Gating, momentary / short-term /
// integrated loudness and LRA are computed from those records elsewhere (AudioAnalysis). The
// one thing that needs a finer grid than 100 ms, the maximum momentary loudness (EBU Tech 3341
// Table 1 cases 13 and 14 shift a 400 ms burst in 20 ms steps and allow +-0.1 LU), is tracked
// here: a 400 ms window slid in 10 ms steps (at most 0.055 LU low), reported per sub-block.
//
// Threading: one producer thread calls lk_process_* (and thereby pushes); one consumer thread
// pops. lk_state itself must only be used by the producer thread.
#ifndef LOUDNESS_KERNEL_H
#define LOUDNESS_KERNEL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version of the kernel's C API; bump on incompatible changes.
/// 2: lk_subblock.max_momentary_mean_square.
#define LK_API_VERSION 2
int lk_api_version(void);

/// Maximum channel count (7.1).
#define LK_MAX_CHANNELS 8

// MARK: - K-weighting

typedef struct lk_biquad_coefficients {
    /// y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]
    double b0, b1, b2, a1, a2;
} lk_biquad_coefficients;

/// Derives the two K-weighting stages for `sample_rate` with the bilinear transform
/// (libebur128's analogue prototype). At 48 kHz this reproduces the BS.1770-5 table.
/// Returns false for a non-finite or out-of-range rate (valid: 8 kHz ... 768 kHz).
bool lk_kweighting_coefficients(double sample_rate, lk_biquad_coefficients *stage1, lk_biquad_coefficients *stage2);

/// True-peak oversampling factor used at `sample_rate`: 4, 2 or 1 (none).
uint32_t lk_true_peak_oversampling(double sample_rate);

/// The interpolation filter used for `oversampling` (4 or 2), for inspection and tests:
/// `*phases` rows of `*taps` coefficients, row-major, coefficient 0 applied to the oldest sample.
/// NULL (and zero counts) for any other factor.
const double *lk_true_peak_filter(uint32_t oversampling, uint32_t *phases, uint32_t *taps);

// MARK: - Host context

/// Flags of lk_host_context.flags.
enum {
    LK_CONTEXT_HAS_BEAT = 1u << 0,      ///< beat_position is valid
    LK_CONTEXT_HAS_TEMPO = 1u << 1,     ///< tempo_bpm is valid
    LK_CONTEXT_HAS_METER = 1u << 2,     ///< meter_numerator / meter_denominator are valid
    LK_CONTEXT_HAS_DOWNBEAT = 1u << 3,  ///< measure_downbeat is valid
    LK_CONTEXT_HAS_TRANSPORT = 1u << 4, ///< the transport flags below are valid
    LK_CONTEXT_PLAYING = 1u << 5,
    LK_CONTEXT_RECORDING = 1u << 6,
    LK_CONTEXT_CYCLING = 1u << 7,
};

/// What the host reported for the first frame of one lk_process_* call (for an AU: the
/// musical context and transport state blocks, read once per render call).
typedef struct lk_host_context {
    uint32_t flags;
    int32_t meter_numerator;
    int32_t meter_denominator;
    uint32_t reserved;
    /// Position of the first frame in quarter-note beats.
    double beat_position;
    double tempo_bpm;
    /// Beat position of the first beat of the bar containing beat_position.
    double measure_downbeat;
} lk_host_context;

// MARK: - Sub-block records

/// Flags of lk_subblock.flags.
enum {
    /// The transport was reported playing for every process call in this sub-block.
    LK_BLOCK_PLAYING = 1u << 0,
    /// The host's beat position jumped (locate, cycle wrap, or a gap in rendering) exactly at
    /// this sub-block's first frame: the sub-block is clean but does not continue the previous one.
    LK_BLOCK_JUMP_BEFORE = 1u << 1,
    /// The beat position jumped after this sub-block's first frame: its audio spans two places.
    LK_BLOCK_JUMP_INSIDE = 1u << 2,
    LK_BLOCK_HAS_BEAT = 1u << 3,
    LK_BLOCK_HAS_TEMPO = 1u << 4,
    LK_BLOCK_HAS_METER = 1u << 5,
    LK_BLOCK_HAS_DOWNBEAT = 1u << 6,
    LK_BLOCK_HAS_TRANSPORT = 1u << 7,
    /// Transport state at the first frame.
    LK_BLOCK_RECORDING = 1u << 8,
    LK_BLOCK_CYCLING = 1u << 9,
};

/// One completed 100 ms sub-block (round(sample_rate / 10) frames).
typedef struct lk_subblock {
    /// Running number since the last reset (0, 1, 2, ...). Gaps mean dropped records.
    uint64_t index;
    /// Frame number (since the last reset) of the first frame.
    uint64_t start_frame;
    uint32_t frames;
    uint32_t flags;
    uint32_t channels;
    int32_t meter_numerator;
    int32_t meter_denominator;
    uint32_t reserved;
    /// Host context at the first frame (extrapolated from the process call's context).
    double beat_position;
    double tempo_bpm;
    double measure_downbeat;
    /// Sum over channels of G_i * z_i (BS.1770 channel weights times K-weighted mean squares).
    double weighted_mean_square;
    /// The largest weighted mean square of a 400 ms window ending inside this sub-block, the
    /// window slid in 10 ms steps (one tenth of a sub-block). 0 when no such window lies within
    /// audio processed since the last reset or jump. A window ending in this sub-block reaches
    /// back into the fourth sub-block before it, so a consumer uses it only when those sub-blocks
    /// continue each other.
    double max_momentary_mean_square;
    /// K-weighted mean square z_i per channel.
    double mean_square[LK_MAX_CHANNELS];
    /// max |x| per channel (linear, unweighted).
    float sample_peak[LK_MAX_CHANNELS];
    /// Oversampled peak per channel (linear, never below the sample peak).
    float true_peak[LK_MAX_CHANNELS];
} lk_subblock;

static inline double lk_subblock_channel_mean_square(const lk_subblock *block, uint32_t channel) {
    return channel < LK_MAX_CHANNELS ? block->mean_square[channel] : 0.0;
}
static inline float lk_subblock_channel_sample_peak(const lk_subblock *block, uint32_t channel) {
    return channel < LK_MAX_CHANNELS ? block->sample_peak[channel] : 0.0f;
}
static inline float lk_subblock_channel_true_peak(const lk_subblock *block, uint32_t channel) {
    return channel < LK_MAX_CHANNELS ? block->true_peak[channel] : 0.0f;
}

// MARK: - Single-producer / single-consumer rings over caller memory (C11 atomics)

typedef struct lk_block_ring lk_block_ring;

/// Bytes needed for a ring of `capacity` records (a power of two, 2 ... 65536); 0 if invalid.
size_t lk_block_ring_bytes(uint32_t capacity);
/// Initialises the ring in `memory` (16-byte aligned, at least lk_block_ring_bytes bytes).
lk_block_ring *lk_block_ring_init(void *memory, size_t bytes, uint32_t capacity);
/// Producer: copies `block` in. Returns false (and counts a drop) when the ring is full.
bool lk_block_ring_push(lk_block_ring *ring, const lk_subblock *block);
/// Consumer: copies the oldest record out. Returns false when empty.
bool lk_block_ring_pop(lk_block_ring *ring, lk_subblock *out);
uint32_t lk_block_ring_count(const lk_block_ring *ring);
uint64_t lk_block_ring_dropped(const lk_block_ring *ring);

/// Mono audio tap for the background spectrum (the mean of all channels, unweighted).
typedef struct lk_sample_ring lk_sample_ring;

size_t lk_sample_ring_bytes(uint32_t capacity);
lk_sample_ring *lk_sample_ring_init(void *memory, size_t bytes, uint32_t capacity);
/// Producer: writes up to `count` samples; returns how many fit (the rest are counted as dropped).
uint32_t lk_sample_ring_write(lk_sample_ring *ring, const float *samples, uint32_t count);
/// Consumer: reads up to `max` samples; returns how many were read.
uint32_t lk_sample_ring_read(lk_sample_ring *ring, float *out, uint32_t max);
uint32_t lk_sample_ring_count(const lk_sample_ring *ring);
uint64_t lk_sample_ring_dropped(const lk_sample_ring *ring);

// MARK: - Kernel

/// Options of lk_config.options.
enum {
    /// Skip the oversampling filter (true_peak then equals sample_peak). For tests that only
    /// need loudness; the plug-in leaves it off.
    LK_OPTION_NO_TRUE_PEAK = 1u << 0,
};

typedef struct lk_config {
    double sample_rate;
    uint32_t channels;
    uint32_t options;
    /// BS.1770 channel weights G_i (1.0 for L/R/C, 1.41 for surrounds, 0 for LFE).
    double channel_weights[LK_MAX_CHANNELS];
    /// A beat-position difference (quarter notes) between consecutive process calls larger than
    /// this counts as a jump. 0 = default (0.02 beats).
    double beat_jump_tolerance;
} lk_config;

typedef struct lk_state lk_state;

size_t lk_state_bytes(void);
/// Initialises a kernel in `memory` (16-byte aligned, at least lk_state_bytes bytes). `blocks`
/// receives completed sub-blocks (required); `tap` receives the mono tap (optional, may be NULL).
/// Returns NULL when the configuration is invalid.
lk_state *lk_state_init(void *memory, size_t bytes, const lk_config *config, lk_block_ring *blocks, lk_sample_ring *tap);
/// Clears filter state, accumulators and counters (the partial sub-block is discarded).
void lk_reset(lk_state *state);

/// Processes `frames` frames of planar audio (`channels[c][i]`). `context` may be NULL.
void lk_process_planar(lk_state *state, const float *const *channels, uint32_t frames, const lk_host_context *context);
/// Processes `frames` frames of interleaved audio (`samples[i * channels + c]`).
void lk_process_interleaved(lk_state *state, const float *samples, uint32_t frames, const lk_host_context *context);

uint32_t lk_state_subblock_frames(const lk_state *state);
uint32_t lk_state_oversampling(const lk_state *state);
uint32_t lk_state_channels(const lk_state *state);
double lk_state_sample_rate(const lk_state *state);

#ifdef __cplusplus
}
#endif

#endif
