#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(NSInteger, CaptureFrameDurationResult) {
    CaptureFrameDurationResultApplied = 0,
    CaptureFrameDurationResultUnsupported = 1,
    CaptureFrameDurationResultException = 2,
};

/// Sets `videoMinFrameDuration` when the connection allows it.
/// Swift cannot catch NSException, and this device throws if a frame
/// duration is written on an unsupported connection. Returns the reason
/// string only for `.exception`. Never touches the device's
/// `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration`.
CaptureFrameDurationResult CaptureSetVideoMinFrameDuration(
    AVCaptureConnection * _Nullable connection,
    CMTime duration,
    NSString * _Nullable * _Nullable failureOut
);
