#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// LogicMCP Meter: a pass-through audio effect (aufx) that measures loudness, peaks and the
/// spectrum of its input and sends them to the logic-mcp server (see MeterSession.swift).
@interface LMCPMeterAudioUnit : AUAudioUnit
@end

/// The extension's principal class: creates the audio unit for the host.
@interface LMCPMeterFactory : NSObject <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
