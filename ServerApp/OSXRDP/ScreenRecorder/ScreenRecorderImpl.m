#import "ScreenRecorderImpl.h"

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#include <math.h>
#include <time.h>
#include "osxrdp/packet.h"
#include "osxrdp/screenrecordshm.h"

@implementation ScreenRecorderImpl {
    SCContentFilter* _recordFilter;
    SCStreamConfiguration* _recordConfig;
    dispatch_queue_t _recordQue;
    SCStream* _recordStream;
    on_record_data _recordCb;
    on_record_cmd _recordCmdCb;
    void* _recordCbUserData;
    void* _recordCmdCbUserData;
    int _displayIdx;
    BOOL _loggedFirstFrame;
    BOOL _loggedAudio;
    uint64_t _profileStartNs, _profileFrames, _profileWorkNs;
    on_record_audio _audioCb;
    void* _audioUserData;
    
    CGRect _dirtyRectBuffer[MAX_DIRTY_COUNT];
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _recordFilter = nil;
        _recordConfig = nil;
        _recordQue = nil;
        _recordStream = nil;
        _recordCb = NULL;
        _recordCbUserData = NULL;
    }
    
    return self;
}

int SetDirtyAreaInfoFromSampleBuffer(CMSampleBufferRef sampleBuffer, CGRect* rects);

- (void)initializeWithDisplayId:(int)displayId
            DisplayIndex:(int)displayIdx
            RecordWidth:(int)width
            RecordHeight:(int)height
            RecordFramerate:(int)framerate
            RecordFormat:(int)recordFormat
            RecordDataCallback:(on_record_data)recordCb
            RecordDataCallbackUserData:(void*)userData
            RecordCmdCallback:(on_record_cmd)recordCmdCb
            RecordCmdCallbackUserData:(void*)userData2 {
    
    SCDisplay* display = [self getDisplayFromDisplayId: displayId];
    if (display == nil) return;
    
    _recordFilter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
    if (_recordFilter == nil) return;
    
    // 녹화 설정 (해상도, 프레임 등)
    _recordConfig = [[SCStreamConfiguration alloc] init];
    _recordConfig.width = width;
    _recordConfig.height = height;
    _recordConfig.queueDepth = 3;
    
    // RDP clients consume SDR RGB; convert the display profile before capture.
    _recordConfig.colorSpaceName = kCGColorSpaceSRGB;
    
    if (recordFormat == OSXRDP_RECORDFORMAT_NV12_PACKED || recordFormat == OSXRDP_RECORDFORMAT_NV12_ALIGNED) {
        // h264 사용 시
        _recordConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    }
    else if (recordFormat == OSXRDP_RECORDFORMAT_RFX) {
        // rfx 사용 시 (ScreenCaptureKit 호환성을 위해 BGRA 캡처 후 상위에서 YUV444 변환)
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }
    else {
        // bitmap 사용 시
        _recordConfig.pixelFormat = kCVPixelFormatType_32BGRA;
    }
    
    _recordConfig.showsCursor = NO;
    // 구형 os 는 screenrecorderfallback 을 사용하도록 함.
    if (@available(macOS 14.0,*)) {
        _recordConfig.preservesAspectRatio = NO;
    }
    
    _recordConfig.minimumFrameInterval = CMTimeMake(1, MAX(1, framerate));
    
    // 녹화 큐 설정
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    _recordQue = dispatch_queue_create("osxrdp.record", attr);
    
    // 녹화 데이터 콜백 (인코딩 한 후 이를 전달하기 위해)
    _recordCb = recordCb;
    _recordCbUserData = userData;
    
    // 녹화 이벤트 콜백 (갑작스러운 녹화 정지 이벤트를 받기 위해)
    _recordCmdCb = recordCmdCb;
    _recordCmdCbUserData = userData2;
    
    _displayIdx = displayIdx;
    _loggedFirstFrame = NO;
    _profileStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _profileFrames = _profileWorkNs = 0;
}

- (BOOL)start {
    if (_recordFilter == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordFilter is NULL\n");
        
        return NO;
    }
    
    if (_recordConfig == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordConfig is NULL\n");
        
        return NO;
    }
    
    if (_recordQue == nil) {
        NSLog(@"[ScreenRecorderImpl::start] recordQue is NULL\n");
        
        return NO;
    }
    
    _recordStream = [[SCStream alloc] initWithFilter:_recordFilter configuration:_recordConfig delegate:self];
    
    NSError* err = nil;
    [_recordStream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:_recordQue error:&err];
    if (err != nil) {
        NSLog(@"[ScreenRecorderImpl::start] addStreamOutput failed. %ld\n", err.code);
        
        return NO;
    }
    if (_audioCb != NULL) {
        [_recordStream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:_recordQue error:&err];
        if (err != nil) {
            NSLog(@"[OSXRDP audio] adding audio output failed: %@", err);
            // Video remains usable if this OS cannot supply audio.
            _audioCb = NULL;
        }
    }
    
    NSLog(@"[ScreenRecorderImpl::start] before start record\n");
    [_recordStream startCaptureWithCompletionHandler:nil];
    NSLog(@"[ScreenRecorderImpl::start] start record\n");

    return YES;
}

- (BOOL)stop {
    if (_recordStream == nil) return YES;
    
    // 녹화 정지 요청 후 완전히 종료될때까지 대기
    __block NSError* stopError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_recordStream stopCaptureWithCompletionHandler:^(NSError* _Nullable err) {
        stopError = err;
        
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    // 아직 녹화가 정지되지 않음. (이 경우 상위의 ScreenRecorder 내부의 공유 메모리를 절대 해제하면 안됨. 녹화 콜백이 다시 발생하여 크래시 발생할 수 있음)
    if (stopError != nil) {
        NSLog(@"[ScreenRecorderImpl::stop] Stop Record failed. %ld\n", stopError.code);
        
        return NO;
    }
    else {
        NSError* err = nil;
        [_recordStream removeStreamOutput:self type:SCStreamOutputTypeScreen error:&err];
        if (_audioCb != NULL)
            [_recordStream removeStreamOutput:self type:SCStreamOutputTypeAudio error:nil];
        // Stop is called by the IPC owner, never by the sample queue. Drain
        // queued samples before its manager and client socket can be released.
        dispatch_sync(_recordQue, ^{});
        _audioCb = NULL;
        _recordStream = nil;
        _recordFilter = nil;
        _recordConfig = nil;

        NSLog(@"[ScreenRecorderImpl::stop] Stop Record\n");
        
        return YES;
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeAudio) {
        [self handleAudioSample:sampleBuffer];
        return;
    }
    if (type != SCStreamOutputTypeScreen) return;
    
    // dirty area 정보 추출
    int dirtyAreaCnt = SetDirtyAreaInfoFromSampleBuffer(sampleBuffer, _dirtyRectBuffer);
    if (dirtyAreaCnt < 0) {
        return;
    }
    
    // ImageBuffer 추출 (CVPixelBufferRef와 동일)
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == NULL) {
        return;
    }
    if (!_loggedFirstFrame) {
        _loggedFirstFrame = YES;
        CGColorSpaceRef space = CVImageBufferGetColorSpace(pixelBuffer);
        CFStringRef name = space != NULL ? CGColorSpaceCopyName(space) : NULL;
        NSLog(@"[OSXRDP capture buffer] actual=%zux%zu format=%u colorSpace=%@",
              CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
              (unsigned)CVPixelBufferGetPixelFormatType(pixelBuffer),
              name != NULL ? (__bridge NSString*)name : @"unnamed");
        if (name != NULL) CFRelease(name);
    }

    uint64_t before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    
    // 콜백 호출 (osxup 로 화면 데이터 전송)
    _recordCb(pixelBuffer, _dirtyRectBuffer, dirtyAreaCnt, _recordCbUserData, _displayIdx);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _profileFrames++; _profileWorkNs += now - before;
    if (_profileStartNs && now - _profileStartNs >= 5000000000ULL) {
        NSLog(@"[OSXRDP capture rate] display=%d fps=%.1f callback_ms=%.2f", _displayIdx,
            _profileFrames * 1e9 / (now - _profileStartNs), _profileWorkNs / (1e6 * _profileFrames));
        _profileStartNs = now; _profileFrames = _profileWorkNs = 0;
    }
}

- (BOOL)isAudioActive { return _audioCb != NULL && _recordStream != nil; }

- (void)setAudioCallback:(on_record_audio)callback userData:(void*)userData {
    if (@available(macOS 13.0, *)) {
        _audioCb = callback;
        _audioUserData = userData;
        _recordConfig.capturesAudio = callback != NULL;
        _recordConfig.sampleRate = 48000;
        _recordConfig.channelCount = 2;
        _recordConfig.excludesCurrentProcessAudio = YES;
    }
}

- (void)handleAudioSample:(CMSampleBufferRef)sample {
    if (_audioCb == NULL || !CMSampleBufferDataIsReady(sample)) return;
    const AudioStreamBasicDescription* format = CMAudioFormatDescriptionGetStreamBasicDescription(
        CMSampleBufferGetFormatDescription(sample));
    if (!format || format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate != 48000
        || format->mChannelsPerFrame != 2 || (format->mFormatFlags & kAudioFormatFlagIsBigEndian)) return;
    BOOL floating = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL planar = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if ((floating && format->mBitsPerChannel != 32)
        || (!floating && (format->mBitsPerChannel != 16 || !(format->mFormatFlags & kAudioFormatFlagIsSignedInteger)))) return;
    struct { AudioBufferList list; AudioBuffer extra; } storage = {0};
    AudioBufferList* buffers = &storage.list;
    CMBlockBufferRef retained = NULL;
    size_t required = 0;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &required,
        NULL, 0, NULL, NULL, 0, NULL);
    if (status != noErr || required > sizeof(storage)) return;
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &required,
        buffers, required, kCFAllocatorDefault, kCFAllocatorDefault,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
    if (status != noErr) { if (retained) CFRelease(retained); return; }
    CMItemCount frames = CMSampleBufferGetNumSamples(sample);
    size_t bytesPerSample = floating ? 4 : 2;
    BOOL valid = frames > 0 && frames <= 48000 && buffers->mNumberBuffers == (planar ? 2 : 1);
    for (unsigned i = 0; valid && i < buffers->mNumberBuffers; ++i) {
        valid = buffers->mBuffers[i].mData != NULL
            && buffers->mBuffers[i].mDataByteSize >= (size_t)frames * bytesPerSample * (planar ? 1 : 2);
    }
    if (valid) {
        if (!_loggedAudio) {
            _loggedAudio = YES;
            NSLog(@"[OSXRDP audio] capturing 48000 Hz stereo PCM");
        }
        double seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample));
        if (!isfinite(seconds) || seconds < 0) seconds = 0;
        uint32_t timestamp = (uint32_t)fmod(seconds * 1000.0, 4294967296.0);
        int16_t pcm[1024 * 2];
        for (CMItemCount first = 0; first < frames; first += 1024) {
            int count = (int)MIN(1024, frames - first);
            for (int i = 0; i < count; ++i) for (int ch = 0; ch < 2; ++ch) {
                const AudioBuffer* buffer = &buffers->mBuffers[planar ? ch : 0];
                size_t index = (first + i) * (planar ? 1 : 2) + (planar ? 0 : ch);
                if (floating) {
                    float value = ((const float*)buffer->mData)[index];
                    pcm[i*2+ch] = !isfinite(value) ? 0 : (int16_t)lrintf(fmaxf(-1.f, fminf(1.f, value)) * 32767.f);
                } else pcm[i*2+ch] = ((const int16_t*)buffer->mData)[index];
            }
            _audioCb(pcm, count, timestamp + (uint32_t)(first * 1000 / 48000), _audioUserData);
        }
    }
    if (retained) CFRelease(retained);
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    // 녹화 정지 요청
    _recordCmdCb(1, _recordCmdCbUserData);
}

// 디스플레이 id 를 사용하여 ScreenCaptureKit 디스플레이 조회
- (SCDisplay*)getDisplayFromDisplayId:(int)displayId {
    __block SCDisplay* found = nil;
    
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        for (SCDisplay* item in content.displays) {
            if (item.displayID == displayId) {
                found = item;
                break;
            }
        }
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    return found;
}

int SetDirtyAreaInfoFromSampleBuffer(CMSampleBufferRef sampleBuffer, CGRect* rects) {
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (arr == NULL || CFArrayGetCount(arr) == 0) {
        return -1;
    }

    CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    if (att == NULL) {
        return -1;
    }
    
    NSNumber* status = (__bridge NSNumber*)CFDictionaryGetValue(att, (__bridge CFStringRef)SCStreamFrameInfoStatus);
    if (status == nil) {
        return -1;
    }

    SCFrameStatus frameStatus = (SCFrameStatus)status.integerValue;
    if (frameStatus != SCFrameStatusComplete) {
        return -1;
    }

    CFArrayRef dirtyArr = (CFArrayRef)CFDictionaryGetValue(att, (__bridge CFStringRef)SCStreamFrameInfoDirtyRects);
    if (dirtyArr == NULL) {
        return 0;
    }
    
    int dirtyAreaCnt = (int)CFArrayGetCount(dirtyArr);
    if (dirtyAreaCnt > MAX_DIRTY_COUNT) return 0;
    
    for (int i = 0; i < dirtyAreaCnt; i++) {
        CFTypeRef element = CFArrayGetValueAtIndex(dirtyArr, i);
        CGRectMakeWithDictionaryRepresentation((CFDictionaryRef)element, &(rects[i]));
    }
    
    return dirtyAreaCnt;
}

@end
