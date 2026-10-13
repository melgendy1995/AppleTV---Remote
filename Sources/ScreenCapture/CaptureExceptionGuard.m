#import "CaptureExceptionGuard.h"

CaptureFrameDurationResult CaptureSetVideoMinFrameDuration(
    AVCaptureConnection *connection,
    CMTime duration,
    NSString *__autoreleasing *failureOut
) {
    if (failureOut) *failureOut = nil;
    if (connection == nil) return CaptureFrameDurationResultUnsupported;
    @try {
        if (!connection.isVideoMinFrameDurationSupported) {
            return CaptureFrameDurationResultUnsupported;
        }
        connection.videoMinFrameDuration = duration;
        return CaptureFrameDurationResultApplied;
    } @catch (NSException *exception) {
        if (failureOut) *failureOut = exception.reason ?: exception.name;
        return CaptureFrameDurationResultException;
    }
}
