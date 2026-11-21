#include "LoudnessKernel.h"

#include <math.h>
#include <stdatomic.h>
#include <string.h>

int lk_api_version(void) { return LK_API_VERSION; }

// MARK: - K-weighting

bool lk_kweighting_coefficients(double sample_rate, lk_biquad_coefficients *stage1, lk_biquad_coefficients *stage2) {
    if (!(sample_rate >= 8000.0 && sample_rate <= 768000.0) || !stage1 || !stage2) return false;
    // Analogue prototype of libebur128 (MIT; ebur128_init_filter), research §6.1. The bilinear
    // transform with these constants reproduces BS.1770-5 Annex 1 Table 1 (stage 1) and Table 2
    // (stage 2), which are given for 48 kHz only, to ~1e-15 (KernelTests). For other rates the
    // Recommendation asks for coefficients "chosen to provide the same frequency response".
    // Stage 1: high shelf ("head" effect).
    double f0 = 1681.974450955533;
    double gain_db = 3.999843853973347;
    double q = 0.7071752369554196;
    double k = tan(M_PI * f0 / sample_rate);
    double vh = pow(10.0, gain_db / 20.0);
    double vb = pow(vh, 0.4996667741545416);
    double a0 = 1.0 + k / q + k * k;
    stage1->b0 = (vh + vb * k / q + k * k) / a0;
    stage1->b1 = 2.0 * (k * k - vh) / a0;
    stage1->b2 = (vh - vb * k / q + k * k) / a0;
    stage1->a1 = 2.0 * (k * k - 1.0) / a0;
    stage1->a2 = (1.0 - k / q + k * k) / a0;
    // Stage 2: RLB high-pass. The numerator stays 1, -2, 1 as in the standard's table.
    f0 = 38.13547087602444;
    q = 0.5003270373238773;
    k = tan(M_PI * f0 / sample_rate);
    a0 = 1.0 + k / q + k * k;
    stage2->b0 = 1.0;
    stage2->b1 = -2.0;
    stage2->b2 = 1.0;
    stage2->a1 = 2.0 * (k * k - 1.0) / a0;
    stage2->a2 = (1.0 - k / q + k * k) / a0;
    return true;
}

// MARK: - True-peak interpolation filters

#define LK_TP_MAX_TAPS 24

// ITU-R BS.1770-5 Annex 2, section 3 ("One set of filter coefficients (for the order 48, 4-phase,
// FIR interpolating) that would satisfy the requirements"): the 48 coefficients, one row per
// phase (12 taps each), exactly as printed in the Recommendation's table (column "Phase p", top to
// bottom). Compared value by value with the BS.1770-5 text on 2026-11-21; TruePeakFilterTests
// keeps a copy of the published table and fails if this one changes. The table is applied with
// coefficient 0 to the oldest sample (the standard's convolution order reversed); that maps phase
// p to phase 3 - p, so the set of four outputs, and therefore the maximum, is the same.
// Also checked (TruePeakTests): the phases' low-frequency group delays sit within 0.07 sample of
// the 1/8, 3/8, 5/8 and 7/8 positions between two input samples; each phase is flat within
// +-0.25 dB up to 20 kHz at 48 kHz; EBU Tech 3341 true-peak cases 15-23 land inside +0.2 / -0.4 dB.
// Annex 2 attenuates by 12.04 dB first only to give integer arithmetic headroom; in floating
// point that step and its compensation cancel, so neither is done here.
static const double lk_tp4_coefficients[4][12] = {
    {0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
     0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500},
    {-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
     0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375},
    {-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
     0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875},
    {-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
     0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750},
};

// 2x oversampling (96 kHz up to 192 kHz input): the original samples plus one half-sample phase.
// The standard gives no 2x table, so this is a 24-tap Kaiser-windowed sinc (beta = 6, cutoff at
// the input Nyquist frequency, normalised to unity DC gain). Its magnitude response is flat
// within +-0.01 dB up to 0.40 x the input rate (38.4 kHz at 96 kHz; 0.015 dB at 0.42 x) and
// its delay is exactly 11.5 samples (checked in TruePeakTests).
static const double lk_tp2_coefficients[1][24] = {
    {-0.00077451571215063147, 0.0020386501959444494, -0.0042312238617131159, 0.0077234268351832639,
     -0.012982931981207377, 0.02063504314986514, -0.031612194419419648, 0.047530738031278351,
     -0.071745514065433197, 0.11296634879211574, -0.2033595118100435, 0.63381168484558048,
     0.63381168484558048, -0.2033595118100435, 0.11296634879211574, -0.071745514065433197,
     0.047530738031278351, -0.031612194419419648, 0.02063504314986514, -0.012982931981207377,
     0.0077234268351832639, -0.0042312238617131159, 0.0020386501959444494, -0.00077451571215063147},
};

const double *lk_true_peak_filter(uint32_t oversampling, uint32_t *phases, uint32_t *taps) {
    uint32_t p = 0, t = 0;
    const double *table = NULL;
    if (oversampling == 4) {
        p = 4;
        t = 12;
        table = &lk_tp4_coefficients[0][0];
    } else if (oversampling == 2) {
        p = 1;
        t = 24;
        table = &lk_tp2_coefficients[0][0];
    }
    if (phases) *phases = p;
    if (taps) *taps = t;
    return table;
}

// BS.1770-5 Annex 2, section 3: 4x takes 48 kHz to 192 kHz; "incoming signals that are at
// higher sampling rates require proportionately less over-sampling (e.g. ... at 96 kHz ... 2x
// would be sufficient)", and the dB TP reading assumes "an oversampled sampling rate of at least
// 192 kHz". So: the smallest factor of 4, 2, 1 that reaches 192 kHz, which is also libebur128's
// rule (4x below 96 kHz, 2x below 192 kHz). Below 48 kHz even 4x stays under 192 kHz (44.1 kHz ->
// 176.4 kHz); the standard's under-read table gives at most 0.55 dB there for content up to
// 0.45 x the sample rate.
uint32_t lk_true_peak_oversampling(double sample_rate) {
    if (!(sample_rate > 0.0) || !isfinite(sample_rate)) return 0;
    if (sample_rate < 96000.0) return 4;
    if (sample_rate < 192000.0) return 2;
    return 1;
}

// MARK: - Rings

struct lk_block_ring {
    _Atomic(uint64_t) head;  // next slot the producer writes
    char pad0[56];           // keep producer and consumer indices on separate cache lines
    _Atomic(uint64_t) tail;  // next slot the consumer reads
    char pad1[56];
    _Atomic(uint64_t) dropped;
    uint32_t capacity;
    uint32_t mask;
    lk_subblock slots[];
};

static bool lk_valid_capacity(uint32_t capacity) {
    return capacity >= 2 && capacity <= 65536u * 16u && (capacity & (capacity - 1)) == 0;
}

size_t lk_block_ring_bytes(uint32_t capacity) {
    if (!lk_valid_capacity(capacity) || capacity > 65536u) return 0;
    return sizeof(struct lk_block_ring) + (size_t)capacity * sizeof(lk_subblock);
}

lk_block_ring *lk_block_ring_init(void *memory, size_t bytes, uint32_t capacity) {
    size_t needed = lk_block_ring_bytes(capacity);
    if (!memory || needed == 0 || bytes < needed || ((uintptr_t)memory % 16) != 0) return NULL;
    memset(memory, 0, needed);
    lk_block_ring *ring = (lk_block_ring *)memory;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->dropped, 0);
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    return ring;
}

bool lk_block_ring_push(lk_block_ring *ring, const lk_subblock *block) {
    if (!ring || !block) return false;
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (head - tail >= ring->capacity) {
        atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
        return false;
    }
    ring->slots[head & ring->mask] = *block;
    atomic_store_explicit(&ring->head, head + 1, memory_order_release);
    return true;
}

bool lk_block_ring_pop(lk_block_ring *ring, lk_subblock *out) {
    if (!ring || !out) return false;
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (tail == head) return false;
    *out = ring->slots[tail & ring->mask];
    atomic_store_explicit(&ring->tail, tail + 1, memory_order_release);
    return true;
}

uint32_t lk_block_ring_count(const lk_block_ring *ring) {
    if (!ring) return 0;
    lk_block_ring *mutable_ring = (lk_block_ring *)ring;
    uint64_t head = atomic_load_explicit(&mutable_ring->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&mutable_ring->tail, memory_order_acquire);
    return (uint32_t)(head - tail);
}

uint64_t lk_block_ring_dropped(const lk_block_ring *ring) {
    if (!ring) return 0;
    return atomic_load_explicit(&((lk_block_ring *)ring)->dropped, memory_order_relaxed);
}

struct lk_sample_ring {
    _Atomic(uint64_t) head;
    char pad0[56];
    _Atomic(uint64_t) tail;
    char pad1[56];
    _Atomic(uint64_t) dropped;
    uint32_t capacity;
    uint32_t mask;
    float samples[];
};

size_t lk_sample_ring_bytes(uint32_t capacity) {
    if (!lk_valid_capacity(capacity)) return 0;
    return sizeof(struct lk_sample_ring) + (size_t)capacity * sizeof(float);
}

lk_sample_ring *lk_sample_ring_init(void *memory, size_t bytes, uint32_t capacity) {
    size_t needed = lk_sample_ring_bytes(capacity);
    if (!memory || needed == 0 || bytes < needed || ((uintptr_t)memory % 16) != 0) return NULL;
    memset(memory, 0, needed);
    lk_sample_ring *ring = (lk_sample_ring *)memory;
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->dropped, 0);
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    return ring;
}

uint32_t lk_sample_ring_write(lk_sample_ring *ring, const float *samples, uint32_t count) {
    if (!ring || !samples || count == 0) return 0;
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    uint64_t space = ring->capacity - (head - tail);
    uint32_t n = count < space ? count : (uint32_t)space;
    for (uint32_t i = 0; i < n; i++) ring->samples[(head + i) & ring->mask] = samples[i];
    if (n < count) atomic_fetch_add_explicit(&ring->dropped, count - n, memory_order_relaxed);
    atomic_store_explicit(&ring->head, head + n, memory_order_release);
    return n;
}

uint32_t lk_sample_ring_read(lk_sample_ring *ring, float *out, uint32_t max) {
    if (!ring || !out || max == 0) return 0;
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    uint64_t available = head - tail;
    uint32_t n = max < available ? max : (uint32_t)available;
    for (uint32_t i = 0; i < n; i++) out[i] = ring->samples[(tail + i) & ring->mask];
    atomic_store_explicit(&ring->tail, tail + n, memory_order_release);
    return n;
}

uint32_t lk_sample_ring_count(const lk_sample_ring *ring) {
    if (!ring) return 0;
    lk_sample_ring *mutable_ring = (lk_sample_ring *)ring;
    uint64_t head = atomic_load_explicit(&mutable_ring->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&mutable_ring->tail, memory_order_acquire);
    return (uint32_t)(head - tail);
}

uint64_t lk_sample_ring_dropped(const lk_sample_ring *ring) {
    if (!ring) return 0;
    return atomic_load_explicit(&((lk_sample_ring *)ring)->dropped, memory_order_relaxed);
}

// MARK: - Kernel state

#define LK_TAP_SCRATCH 256
/// Momentary window in slots of a tenth of a sub-block (10 ms): 40 slots = 400 ms.
#define LK_SLOTS_PER_BLOCK 10
#define LK_MOMENTARY_SLOTS 40

struct lk_state {
    double sample_rate;
    uint32_t channels;
    uint32_t options;
    uint32_t block_frames;
    uint32_t oversampling;
    uint32_t tp_taps;
    uint32_t tp_phases;
    const double *tp_coefficients;  // tp_phases x tp_taps, index 0 = oldest sample
    double weights[LK_MAX_CHANNELS];
    double jump_tolerance;
    lk_biquad_coefficients stage1;
    lk_biquad_coefficients stage2;
    lk_block_ring *blocks;
    lk_sample_ring *tap;

    // Filter state per channel: stage 1 (z1, z2), stage 2 (z1, z2), transposed direct form II.
    double filter[LK_MAX_CHANNELS][4];
    // True-peak delay line, stored twice so the newest `taps` samples are always contiguous.
    double tp_history[LK_MAX_CHANNELS][2 * LK_TP_MAX_TAPS];
    uint32_t tp_position[LK_MAX_CHANNELS];

    // Current sub-block.
    uint32_t in_block;
    uint32_t block_flags;
    uint64_t block_index;
    uint64_t block_start_frame;
    uint64_t frame_counter;
    double block_beat;
    double block_tempo;
    double block_downbeat;
    int32_t block_meter_numerator;
    int32_t block_meter_denominator;
    double sum_squares[LK_MAX_CHANNELS];
    double sample_peak[LK_MAX_CHANNELS];
    double true_peak[LK_MAX_CHANNELS];

    // Sliding momentary window (EBU Tech 3341 cases 13/14): the sub-block is cut into
    // LK_SLOTS_PER_BLOCK slots (the last one takes the remainder), each slot's weighted sum of
    // squares goes into a ring of the last LK_MOMENTARY_SLOTS slots.
    uint32_t slot_frames;          // frames of slots 0 ... 8 (block_frames / 10)
    uint32_t slot;                 // current slot in the sub-block, 0 ... 9
    uint32_t in_slot;              // frames of the current slot so far
    double slot_squares[LK_MAX_CHANNELS];
    double ring_energy[LK_MOMENTARY_SLOTS];
    uint32_t ring_frames[LK_MOMENTARY_SLOTS];
    uint32_t ring_head;            // next slot to write
    uint32_t ring_valid;           // consecutive clean slots in the ring (at most 40)
    bool slot_tainted;             // the current slot started before a jump
    double block_max_momentary;    // largest window ending in the current sub-block

    // Previous process call, for jump detection.
    bool previous_valid;
    double previous_beat;
    double previous_advance;

    float tap_scratch[LK_TAP_SCRATCH];
};

size_t lk_state_bytes(void) { return sizeof(struct lk_state); }

static void lk_clear(lk_state *state) {
    memset(state->filter, 0, sizeof state->filter);
    memset(state->tp_history, 0, sizeof state->tp_history);
    memset(state->tp_position, 0, sizeof state->tp_position);
    memset(state->sum_squares, 0, sizeof state->sum_squares);
    memset(state->sample_peak, 0, sizeof state->sample_peak);
    memset(state->true_peak, 0, sizeof state->true_peak);
    memset(state->slot_squares, 0, sizeof state->slot_squares);
    memset(state->ring_energy, 0, sizeof state->ring_energy);
    memset(state->ring_frames, 0, sizeof state->ring_frames);
    state->slot = 0;
    state->in_slot = 0;
    state->ring_head = 0;
    state->ring_valid = 0;
    state->slot_tainted = false;
    state->block_max_momentary = 0.0;
    state->in_block = 0;
    state->block_flags = 0;
    state->block_index = 0;
    state->block_start_frame = 0;
    state->frame_counter = 0;
    state->previous_valid = false;
    state->previous_beat = 0.0;
    state->previous_advance = 0.0;
}

lk_state *lk_state_init(void *memory, size_t bytes, const lk_config *config, lk_block_ring *blocks, lk_sample_ring *tap) {
    if (!memory || bytes < sizeof(struct lk_state) || ((uintptr_t)memory % 16) != 0 || !config || !blocks) return NULL;
    if (config->channels < 1 || config->channels > LK_MAX_CHANNELS) return NULL;
    lk_biquad_coefficients s1, s2;
    if (!lk_kweighting_coefficients(config->sample_rate, &s1, &s2)) return NULL;
    for (uint32_t c = 0; c < config->channels; c++) {
        double w = config->channel_weights[c];
        if (!(w >= 0.0 && w <= 10.0)) return NULL;
    }
    lk_state *state = (lk_state *)memory;
    memset(state, 0, sizeof *state);
    state->sample_rate = config->sample_rate;
    state->channels = config->channels;
    state->options = config->options;
    state->block_frames = (uint32_t)lround(config->sample_rate / 10.0);
    state->slot_frames = state->block_frames / LK_SLOTS_PER_BLOCK;
    state->stage1 = s1;
    state->stage2 = s2;
    for (uint32_t c = 0; c < config->channels; c++) state->weights[c] = config->channel_weights[c];
    double tolerance = config->beat_jump_tolerance;
    state->jump_tolerance = (tolerance > 0.0 && isfinite(tolerance)) ? tolerance : 0.02;
    state->blocks = blocks;
    state->tap = tap;
    state->oversampling = (config->options & LK_OPTION_NO_TRUE_PEAK) ? 1 : lk_true_peak_oversampling(config->sample_rate);
    switch (state->oversampling) {
    case 4:
        state->tp_taps = 12;
        state->tp_phases = 4;
        state->tp_coefficients = &lk_tp4_coefficients[0][0];
        break;
    case 2:
        state->tp_taps = 24;
        state->tp_phases = 1;
        state->tp_coefficients = &lk_tp2_coefficients[0][0];
        break;
    default:
        state->oversampling = 1;
        state->tp_taps = 0;
        state->tp_phases = 0;
        state->tp_coefficients = NULL;
        break;
    }
    lk_clear(state);
    return state;
}

void lk_reset(lk_state *state) {
    if (state) lk_clear(state);
}

uint32_t lk_state_subblock_frames(const lk_state *state) { return state ? state->block_frames : 0; }
uint32_t lk_state_oversampling(const lk_state *state) { return state ? state->oversampling : 0; }
uint32_t lk_state_channels(const lk_state *state) { return state ? state->channels : 0; }
double lk_state_sample_rate(const lk_state *state) { return state ? state->sample_rate : 0.0; }

// MARK: - Processing

static inline double lk_flush(double value) { return fabs(value) < 1e-25 ? 0.0 : value; }

static inline bool lk_context_has(const lk_host_context *context, uint32_t flag) {
    return context && (context->flags & flag) != 0;
}

static bool lk_context_playing(const lk_host_context *context) {
    return lk_context_has(context, LK_CONTEXT_HAS_TRANSPORT) && lk_context_has(context, LK_CONTEXT_PLAYING);
}

static bool lk_context_tempo(const lk_host_context *context, double *tempo) {
    if (!lk_context_has(context, LK_CONTEXT_HAS_TEMPO)) return false;
    double t = context->tempo_bpm;
    if (!(t > 0.0 && t < 100000.0)) return false;
    *tempo = t;
    return true;
}

static bool lk_context_beat(const lk_host_context *context, double *beat) {
    if (!lk_context_has(context, LK_CONTEXT_HAS_BEAT) || !isfinite(context->beat_position)) return false;
    *beat = context->beat_position;
    return true;
}

/// True when the host's beat position does not follow on from the previous call.
static bool lk_detect_jump(const lk_state *state, const lk_host_context *context) {
    double beat;
    if (!state->previous_valid || !lk_context_beat(context, &beat)) return false;
    double expected = state->previous_beat + state->previous_advance;
    return fabs(beat - expected) > state->jump_tolerance;
}

static void lk_begin_block(lk_state *state, const lk_host_context *context, uint32_t offset) {
    uint32_t flags = 0;
    if (lk_context_playing(context)) flags |= LK_BLOCK_PLAYING;
    if (lk_context_has(context, LK_CONTEXT_HAS_TRANSPORT)) {
        flags |= LK_BLOCK_HAS_TRANSPORT;
        if (lk_context_has(context, LK_CONTEXT_RECORDING)) flags |= LK_BLOCK_RECORDING;
        if (lk_context_has(context, LK_CONTEXT_CYCLING)) flags |= LK_BLOCK_CYCLING;
    }
    double tempo = 0.0, beat = 0.0;
    bool has_tempo = lk_context_tempo(context, &tempo);
    bool has_beat = lk_context_beat(context, &beat);
    bool playing = (flags & LK_BLOCK_PLAYING) != 0;
    state->block_tempo = has_tempo ? tempo : 0.0;
    if (has_tempo) flags |= LK_BLOCK_HAS_TEMPO;
    state->block_beat = 0.0;
    if (has_beat && (offset == 0 || !playing || has_tempo)) {
        // Extrapolate from the call's first frame; the playhead only moves while playing.
        state->block_beat = beat + (playing && offset > 0 ? (double)offset * tempo / (60.0 * state->sample_rate) : 0.0);
        flags |= LK_BLOCK_HAS_BEAT;
    }
    state->block_meter_numerator = 0;
    state->block_meter_denominator = 0;
    double beats_per_bar = 0.0;
    if (lk_context_has(context, LK_CONTEXT_HAS_METER) && context->meter_numerator > 0 && context->meter_denominator > 0) {
        state->block_meter_numerator = context->meter_numerator;
        state->block_meter_denominator = context->meter_denominator;
        beats_per_bar = 4.0 * (double)context->meter_numerator / (double)context->meter_denominator;
        flags |= LK_BLOCK_HAS_METER;
    }
    state->block_downbeat = 0.0;
    if (lk_context_has(context, LK_CONTEXT_HAS_DOWNBEAT) && isfinite(context->measure_downbeat)) {
        double downbeat = context->measure_downbeat;
        if ((flags & LK_BLOCK_HAS_BEAT) && beats_per_bar > 0.0) {
            // The extrapolated position may have crossed into a later bar.
            double bars = floor((state->block_beat - downbeat) / beats_per_bar);
            if (bars > 0.0 && bars < 1.0e6) downbeat += bars * beats_per_bar;
        }
        state->block_downbeat = downbeat;
        flags |= LK_BLOCK_HAS_DOWNBEAT;
    }
    state->block_flags = flags;
    state->block_start_frame = state->frame_counter;
}

static void lk_finish_block(lk_state *state) {
    lk_subblock block;
    memset(&block, 0, sizeof block);
    block.index = state->block_index++;
    block.start_frame = state->block_start_frame;
    block.frames = state->in_block;
    block.flags = state->block_flags;
    block.channels = state->channels;
    block.meter_numerator = state->block_meter_numerator;
    block.meter_denominator = state->block_meter_denominator;
    block.beat_position = state->block_beat;
    block.tempo_bpm = state->block_tempo;
    block.measure_downbeat = state->block_downbeat;
    double weighted = 0.0;
    double frames = (double)state->in_block;
    for (uint32_t c = 0; c < state->channels; c++) {
        double mean_square = state->sum_squares[c] / frames;
        block.mean_square[c] = mean_square;
        weighted += state->weights[c] * mean_square;
        double peak = state->sample_peak[c];
        double true_peak = state->true_peak[c] > peak ? state->true_peak[c] : peak;
        block.sample_peak[c] = (float)peak;
        block.true_peak[c] = (float)true_peak;
        state->sum_squares[c] = 0.0;
        state->sample_peak[c] = 0.0;
        state->true_peak[c] = 0.0;
    }
    block.weighted_mean_square = weighted;
    block.max_momentary_mean_square = state->block_max_momentary;
    state->block_max_momentary = 0.0;
    lk_block_ring_push(state->blocks, &block);
    state->in_block = 0;
}

/// Frames in the current slot: block_frames / 10 for slots 0 ... 8, the rest for slot 9, so the
/// last slot ends exactly with the sub-block and any 40 consecutive slots hold 400 ms.
static inline uint32_t lk_slot_length(const lk_state *state) {
    return state->slot + 1 < LK_SLOTS_PER_BLOCK
        ? state->slot_frames
        : state->block_frames - (LK_SLOTS_PER_BLOCK - 1) * state->slot_frames;
}

/// Closes the current slot: its weighted sum of squares enters the ring, and once the ring holds
/// 400 ms of clean audio the window ending here competes for the sub-block's maximum.
static void lk_finish_slot(lk_state *state) {
    double energy = 0.0;
    for (uint32_t c = 0; c < state->channels; c++) {
        energy += state->weights[c] * state->slot_squares[c];
        state->slot_squares[c] = 0.0;
    }
    state->ring_energy[state->ring_head] = energy;
    state->ring_frames[state->ring_head] = state->in_slot;
    state->ring_head = state->ring_head + 1 == LK_MOMENTARY_SLOTS ? 0 : state->ring_head + 1;
    if (state->slot_tainted) {
        // Audio from both sides of a jump: no window may contain this slot.
        state->ring_valid = 0;
        state->slot_tainted = false;
    } else if (state->ring_valid < LK_MOMENTARY_SLOTS) {
        state->ring_valid++;
    }
    if (state->ring_valid == LK_MOMENTARY_SLOTS) {
        double total = 0.0;
        uint64_t frames = 0;
        for (uint32_t i = 0; i < LK_MOMENTARY_SLOTS; i++) {
            total += state->ring_energy[i];
            frames += state->ring_frames[i];
        }
        double mean = frames > 0 ? total / (double)frames : 0.0;
        if (mean > state->block_max_momentary) state->block_max_momentary = mean;
    }
    state->in_slot = 0;
    state->slot = state->slot + 1 == LK_SLOTS_PER_BLOCK ? 0 : state->slot + 1;
}

/// K-weighting, sum of squares and sample peak for `count` samples of one channel.
static void lk_measure(lk_state *state, uint32_t channel, const float *samples, size_t stride, uint32_t count) {
    const lk_biquad_coefficients s1 = state->stage1;
    const lk_biquad_coefficients s2 = state->stage2;
    double *z = state->filter[channel];
    double z11 = z[0], z12 = z[1], z21 = z[2], z22 = z[3];
    double sum = 0.0;
    double peak = state->sample_peak[channel];
    for (uint32_t i = 0; i < count; i++) {
        double x = (double)samples[i * stride];
        if (!isfinite(x)) x = 0.0;  // a NaN would poison the filter state for good
        double y1 = s1.b0 * x + z11;
        z11 = s1.b1 * x - s1.a1 * y1 + z12;
        z12 = s1.b2 * x - s1.a2 * y1;
        double y2 = s2.b0 * y1 + z21;
        z21 = s2.b1 * y1 - s2.a1 * y2 + z22;
        z22 = s2.b2 * y1 - s2.a2 * y2;
        sum += y2 * y2;
        double magnitude = fabs(x);
        if (magnitude > peak) peak = magnitude;
    }
    z[0] = lk_flush(z11);
    z[1] = lk_flush(z12);
    z[2] = lk_flush(z21);
    z[3] = lk_flush(z22);
    state->sum_squares[channel] += sum;
    state->slot_squares[channel] += sum;
    state->sample_peak[channel] = peak;

    if (state->tp_taps == 0) return;
    const uint32_t taps = state->tp_taps;
    const uint32_t phases = state->tp_phases;
    const double *coefficients = state->tp_coefficients;
    double *history = state->tp_history[channel];
    uint32_t position = state->tp_position[channel];
    double true_peak = state->true_peak[channel];
    for (uint32_t i = 0; i < count; i++) {
        double x = (double)samples[i * stride];
        if (!isfinite(x)) x = 0.0;
        position = position + 1 == taps ? 0 : position + 1;
        history[position] = x;
        history[position + taps] = x;
        const double *window = history + position + 1;  // oldest ... newest
        for (uint32_t p = 0; p < phases; p++) {
            const double *c = coefficients + p * taps;
            double acc = 0.0;
            for (uint32_t k = 0; k < taps; k++) acc += c[k] * window[k];
            acc = fabs(acc);
            if (acc > true_peak) true_peak = acc;
        }
    }
    state->tp_position[channel] = position;
    state->true_peak[channel] = true_peak;
}

static void lk_write_tap(lk_state *state, const float *const *planar, const float *interleaved, uint32_t offset, uint32_t count) {
    if (!state->tap) return;
    const uint32_t channels = state->channels;
    const float scale = 1.0f / (float)channels;
    uint32_t done = 0;
    while (done < count) {
        uint32_t n = count - done < LK_TAP_SCRATCH ? count - done : LK_TAP_SCRATCH;
        for (uint32_t i = 0; i < n; i++) {
            float sum = 0.0f;
            uint32_t frame = offset + done + i;
            for (uint32_t c = 0; c < channels; c++) {
                sum += planar ? planar[c][frame] : interleaved[(size_t)frame * channels + c];
            }
            float value = sum * scale;
            state->tap_scratch[i] = isfinite(value) ? value : 0.0f;
        }
        lk_sample_ring_write(state->tap, state->tap_scratch, n);
        done += n;
    }
}

static void lk_process(lk_state *state, const float *const *planar, const float *interleaved, uint32_t frames, const lk_host_context *context) {
    if (!state || (!planar && !interleaved)) return;
    if (planar) {
        for (uint32_t c = 0; c < state->channels; c++) {
            if (!planar[c]) return;
        }
    }
    bool jump = lk_detect_jump(state, context);
    bool playing = lk_context_playing(context);
    if (jump) {
        // No momentary window may span the jump.
        state->ring_valid = 0;
        state->slot_tainted = state->in_slot > 0;
    }
    uint32_t offset = 0;
    while (offset < frames) {
        if (state->in_block == 0) {
            lk_begin_block(state, context, offset);
            if (jump && offset == 0) state->block_flags |= LK_BLOCK_JUMP_BEFORE;
        } else if (offset == 0) {
            // This call continues a sub-block that an earlier call started.
            if (jump) state->block_flags |= LK_BLOCK_JUMP_INSIDE;
            if (!playing) state->block_flags &= ~(uint32_t)LK_BLOCK_PLAYING;
        }
        uint32_t remaining = state->block_frames - state->in_block;
        uint32_t slot_remaining = lk_slot_length(state) - state->in_slot;
        if (slot_remaining < remaining) remaining = slot_remaining;
        uint32_t n = frames - offset < remaining ? frames - offset : remaining;
        for (uint32_t c = 0; c < state->channels; c++) {
            if (planar) {
                lk_measure(state, c, planar[c] + offset, 1, n);
            } else {
                lk_measure(state, c, interleaved + (size_t)offset * state->channels + c, state->channels, n);
            }
        }
        lk_write_tap(state, planar, interleaved, offset, n);
        state->in_block += n;
        state->in_slot += n;
        state->frame_counter += n;
        offset += n;
        // The last slot ends with the sub-block, so its window counts for this sub-block.
        if (state->in_slot == lk_slot_length(state)) lk_finish_slot(state);
        if (state->in_block == state->block_frames) lk_finish_block(state);
    }
    double beat = 0.0, tempo = 0.0;
    state->previous_valid = lk_context_beat(context, &beat);
    state->previous_beat = beat;
    state->previous_advance = (playing && lk_context_tempo(context, &tempo))
        ? (double)frames * tempo / (60.0 * state->sample_rate) : 0.0;
}

void lk_process_planar(lk_state *state, const float *const *channels, uint32_t frames, const lk_host_context *context) {
    if (!channels) return;
    lk_process(state, channels, NULL, frames, context);
}

void lk_process_interleaved(lk_state *state, const float *samples, uint32_t frames, const lk_host_context *context) {
    if (!samples) return;
    lk_process(state, NULL, samples, frames, context);
}
