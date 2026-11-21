#import "LMCPMeterAudioUnit.h"

#import <AVFoundation/AVFoundation.h>
@import LoudnessKernel;
#import "LogicMCPMeterExtension-Swift.h"

/// Upper bound on channels the meter accepts (the kernel's LK_MAX_CHANNELS is at least this).
static const UInt32 kMaxChannels = 8;

/// What the render block reads. Written only while the host is not rendering (in
/// allocate/deallocateRenderResources), read only by the render block.
typedef struct LMCPRenderState {
    lk_state *_Nullable kernel;
    AudioBufferList *_Nullable input;
    float *_Nullable inputData[kMaxChannels];
    UInt32 channels;
    UInt32 maxFrames;
    __strong AUHostMusicalContextBlock _Nullable musical;
    __strong AUHostTransportStateBlock _Nullable transport;
} LMCPRenderState;

/// Fills the kernel's host context from the host's blocks (called once per render).
static void LMCPReadHostContext(const LMCPRenderState *state, lk_host_context *context) {
    context->flags = 0;
    if (state->musical) {
        double tempo = 0, numerator = 0, beat = 0, downbeat = 0;
        NSInteger denominator = 0, sampleOffsetToNextBeat = 0;
        if (state->musical(&tempo, &numerator, &denominator, &beat, &sampleOffsetToNextBeat, &downbeat)) {
            context->beat_position = beat;
            context->flags |= LK_CONTEXT_HAS_BEAT;
            if (tempo > 0) {
                context->tempo_bpm = tempo;
                context->flags |= LK_CONTEXT_HAS_TEMPO;
            }
            if (numerator >= 1 && numerator <= 64 && denominator >= 1 && denominator <= 64) {
                context->meter_numerator = (int32_t)numerator;
                context->meter_denominator = (int32_t)denominator;
                context->flags |= LK_CONTEXT_HAS_METER;
            }
            context->measure_downbeat = downbeat;
            context->flags |= LK_CONTEXT_HAS_DOWNBEAT;
        }
    }
    if (state->transport) {
        AUHostTransportStateFlags flags = 0;
        double samplePosition = 0, cycleStart = 0, cycleEnd = 0;
        if (state->transport(&flags, &samplePosition, &cycleStart, &cycleEnd)) {
            context->flags |= LK_CONTEXT_HAS_TRANSPORT;
            if (flags & AUHostTransportStateMoving) context->flags |= LK_CONTEXT_PLAYING;
            if (flags & AUHostTransportStateRecording) context->flags |= LK_CONTEXT_RECORDING;
            if (flags & AUHostTransportStateCycling) context->flags |= LK_CONTEXT_CYCLING;
        }
    }
}

@implementation LMCPMeterAudioUnit {
    AUAudioUnitBus *_inputBus;
    AUAudioUnitBus *_outputBus;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AVAudioPCMBuffer *_inputBuffer;
    LMCPMeterSession *_session;
    LMCPRenderState _render;
    /// One id per plug-in instance, kept across render-resource reallocations.
    NSString *_instanceID;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)componentDescription
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:componentDescription options:options error:outError];
    if (self == nil) { return nil; }
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    if (_inputBus == nil || _outputBus == nil) { return nil; }
    _inputBus.maximumChannelCount = kMaxChannels;
    _outputBus.maximumChannelCount = kMaxChannels;
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    self.maximumFramesToRender = 4096;
    _instanceID = [[NSUUID UUID].UUIDString lowercaseString];
    [self addObserver:self forKeyPath:@"contextName" options:NSKeyValueObservingOptionNew context:NULL];
    return self;
}

- (void)dealloc {
    [self removeObserver:self forKeyPath:@"contextName"];
    [_session stop];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contextName"]) {
        [_session setContextName:self.contextName];
    }
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

/// The same channel count in and out, any count the bus accepts.
- (NSArray<NSNumber *> *)channelCapabilities { return @[@(-1), @(-1)]; }

- (BOOL)canProcessInPlace { return YES; }

- (NSString *)audioUnitShortName { return @"LMCP Meter"; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) { return NO; }
    AVAudioFormat *format = _outputBus.format;
    AVAudioChannelCount channels = format.channelCount;
    if (_inputBus.format.channelCount != channels || channels < 1 || channels > kMaxChannels
        || format.commonFormat != AVAudioPCMFormatFloat32 || format.isInterleaved) {
        if (outError) { *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil]; }
        [super deallocateRenderResources];
        return NO;
    }
    _inputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_inputBus.format frameCapacity:self.maximumFramesToRender];
    NSString *version = [NSBundle bundleForClass:[self class]].infoDictionary[@"CFBundleShortVersionString"];
    _session = [[LMCPMeterSession alloc] initWithSampleRate:format.sampleRate channels:channels
                                                 contextName:self.contextName pluginVersion:version
                                                  instanceID:_instanceID];
    if (_inputBuffer == nil || _session == nil) {
        if (outError) { *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FailedInitialization userInfo:nil]; }
        _inputBuffer = nil;
        _session = nil;
        [super deallocateRenderResources];
        return NO;
    }
    AudioBufferList *list = _inputBuffer.mutableAudioBufferList;
    _render.input = list;
    for (UInt32 c = 0; c < channels; ++c) { _render.inputData[c] = (float *)list->mBuffers[c].mData; }
    _render.channels = channels;
    _render.maxFrames = self.maximumFramesToRender;
    _render.musical = self.musicalContextBlock;
    _render.transport = self.transportStateBlock;
    _render.kernel = (lk_state *)_session.kernelState;
    [_session start];
    return YES;
}

- (void)deallocateRenderResources {
    _render.kernel = NULL;
    _render.input = NULL;
    _render.musical = nil;
    _render.transport = nil;
    [_session stop];
    _session = nil;
    _inputBuffer = nil;
    [super deallocateRenderResources];
}

- (AUInternalRenderBlock)internalRenderBlock {
    // The block reads only this struct: no Objective-C messages, allocation or locks.
    LMCPRenderState *state = &_render;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber,
                              AudioBufferList *outputData, const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock pullInputBlock) {
        AudioBufferList *input = state->input;
        if (input == NULL || pullInputBlock == nil) { return kAudioUnitErr_Uninitialized; }
        if (frameCount > state->maxFrames) { return kAudioUnitErr_TooManyFramesToProcess; }
        const UInt32 bytes = frameCount * (UInt32)sizeof(float);
        for (UInt32 c = 0; c < input->mNumberBuffers && c < kMaxChannels; ++c) {
            input->mBuffers[c].mData = state->inputData[c];
            input->mBuffers[c].mDataByteSize = bytes;
        }
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, input);
        if (status != noErr) { return status; }

        // Pass the input through unchanged.
        const UInt32 channels = MIN(outputData->mNumberBuffers, input->mNumberBuffers);
        for (UInt32 c = 0; c < channels; ++c) {
            if (outputData->mBuffers[c].mData == NULL) {
                outputData->mBuffers[c].mData = input->mBuffers[c].mData;
            } else if (outputData->mBuffers[c].mData != input->mBuffers[c].mData) {
                memcpy(outputData->mBuffers[c].mData, input->mBuffers[c].mData, bytes);
            }
            outputData->mBuffers[c].mDataByteSize = bytes;
        }

        lk_state *kernel = state->kernel;
        if (kernel != NULL && channels == state->channels) {
            const float *pointers[kMaxChannels];
            for (UInt32 c = 0; c < channels; ++c) { pointers[c] = (const float *)outputData->mBuffers[c].mData; }
            lk_host_context context = {0};
            LMCPReadHostContext(state, &context);
            lk_process_planar(kernel, pointers, frameCount, &context);
        }
        return noErr;
    };
}

@end

@implementation LMCPMeterFactory

- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc error:(NSError **)error {
    return [[LMCPMeterAudioUnit alloc] initWithComponentDescription:desc error:error];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
}

@end
