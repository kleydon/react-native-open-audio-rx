#import "OpenAudioRx.h"

#include <math.h>
#include <limits.h> //for SCHAR_MAX, SHRT_MAX
#include <float.h> //for DBL_MAX

@implementation OpenAudioRx

static NSString* frameDataEvent = @"frameDataEvent";
static NSString* volumeEvent = @"volumeEvent";
static NSString* stopEvent = @"stopEvent";

static NSString* STOP_CODE_USER_REQUEST = @"STOP_CODE_USER_REQUEST";
static NSString* STOP_CODE_MAX_NUM_SAMPLES_REACHED = @"STOP_CODE_MAX_NUM_SAMPLES_REACHED";
static NSString* STOP_CODE_ERROR = @"STOP_CODE_ERROR";

static NSString* FILE_PATH_NA = @"FILE_PATH_NA";

static uint32_t DEFAULT_MAX_DURATION = 10; //Seconds

static double MAX_VOLUME = 0.0; //dbFS
static double MIN_VOLUME = -100.0; //dbFS


RCT_EXPORT_MODULE()


RCT_EXPORT_METHOD(init:(NSDictionary *) ops) { //Options

    RCTLogInfo(@"init");
    
    const NSString* sampleRateKey = @"sampleRate";
    const NSString* byteDepthKey = @"byteDepth";
    const NSString* numChannelsKey = @"numChannels";
    const NSString* maxDurationKey = @"maxDuration"; //Seconds
    const NSString* reportFrameDataKey = @"reportFrameData";
    const NSString* reportVolumeKey = @"reportVolume";
    const NSString* recordToFileKey = @"recordToFile";

    double sampleRate = ops[sampleRateKey] == nil ? 44100 : [ops[sampleRateKey]  doubleValue];
    uint32_t byteDepth = ops[byteDepthKey] == nil ? 2 : [ops[byteDepthKey] unsignedIntValue];
    uint32_t numChannels = ops[numChannelsKey] == nil ? 1 : [ops[numChannelsKey] unsignedIntValue];
    uint32_t maxNumSamples = ops[maxDurationKey] == nil ?
        sampleRate * DEFAULT_MAX_DURATION :
        sampleRate * [ops[maxDurationKey] unsignedIntValue];
    bool reportFrameData = ops[reportFrameDataKey] == nil ? false : [ops[reportFrameDataKey] boolValue];
    bool reportVolume = ops[reportVolumeKey] == nil ? false : [ops[reportVolumeKey] boolValue];
    bool recordToFile = ops[recordToFileKey] == nil ? true : [ops[recordToFileKey] boolValue];
    
    _rxState.format.mSampleRate        = sampleRate;
    _rxState.format.mBitsPerChannel    = byteDepth * 8;
    _rxState.format.mChannelsPerFrame  = numChannels;
    _rxState.format.mBytesPerPacket    = byteDepth * numChannels;
    _rxState.format.mBytesPerFrame     = _rxState.format.mBytesPerPacket;
    _rxState.format.mFramesPerPacket   = 1;
    _rxState.format.mReserved          = 0;
    _rxState.format.mFormatID          = kAudioFormatLinearPCM;
    _rxState.format.mFormatFlags       = (byteDepth == 1) ?
        kLinearPCMFormatFlagIsPacked : (kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked);

    _rxState.self = self;
    _rxState.frameBufferSize = 2048; //bytes
    _rxState.maxNumSamples = maxNumSamples;
    _rxState.reportFrameData = reportFrameData;
    _rxState.reportVolume = reportVolume;
    _rxState.recordToFile = recordToFile;
    _rxState.recordingFileId = 0; //Doesn't yet exist

    _filePath = nil;
    if (recordToFile) {
        NSString *dirPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *fileName =  @"react-native-open-rx-recording.wav";
        _filePath = [NSString stringWithFormat:@"%@/%@", dirPath, fileName];
    }
    
    printf("Sample Rate: %f\n", sampleRate);
    printf("Byte Depth: %d\n", byteDepth);
    printf("numChannels: %d\n", numChannels);
    printf("maxNumSamples: %d\n", maxNumSamples);
    printf("reportFrameData: %s\n", reportFrameData ? "true" : "false");
    printf("reportVolume: %s\n", reportVolume ? "true" : "false");
    printf("recordToFile: %s\n", recordToFile ? "true" : "false");
    printf("frameBufferSize: %d\n", _rxState.frameBufferSize);
    printf("filePath: %s\n", [_filePath cStringUsingEncoding:NSASCIIStringEncoding]);
}


RCT_REMAP_METHOD(start,
                 startWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {

    RCTLogInfo(@"start");

    AVAudioSession* avAudioSession = [AVAudioSession sharedInstance];
    BOOL result = YES;
    NSError* error = nil;
    OSStatus osStatusCode = 0;
        
    //Set to record
    result = [avAudioSession setCategory:(AVAudioSessionCategory)AVAudioSessionCategoryRecord error:&error];
    if (!result) {
        RCTLogInfo(@"Error calling setCategory %ld %@", error.code, error.localizedDescription);
        reject([@(error.code) stringValue], @"Error calling setCategory", error);
        return;
    }
    
    //Set to measurement audio
    result = [avAudioSession setMode:(AVAudioSessionMode)AVAudioSessionModeMeasurement error:&error];
    if (!result) {
        RCTLogInfo(@"Error calling setMode %ld %@", error.code, error.localizedDescription);
        reject(@"Error in start()", @"Error calling setMode", error);
        return;
    }

    _rxState.isReceiving = true;
    _rxState.currentPacket = 0;
    _rxState.numSamplesProcessed = 0;
  
    if (_rxState.recordToFile) {
        CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
        osStatusCode = AudioFileCreateWithURL(url,
                                              kAudioFileWAVEType,
                                              &_rxState.format,
                                              kAudioFileFlags_EraseFile,
                                              &_rxState.recordingFileId);
        if (url) {
            CFRelease(url);
        }
        
        if (osStatusCode) {
            NSString* errorMsg = @"Error calling AudioFileCreateWithURL";
            error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                               code:osStatusCode
                                           userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
            reject([@(osStatusCode) stringValue], errorMsg, error);
            return;
        }
    }
      
    osStatusCode = AudioQueueNewInput(&_rxState.format, //inFormat
                                      HandleInputBuffer, //inCallbackProc
                                      &_rxState, //inUserData
                                      NULL, //inCallbackRunLoop
                                      NULL, //inCallbackRunLoopMode
                                      0, //inFlags
                                      &_rxState.queue); //outAQ
    if (osStatusCode) {
        NSString* errorMsg = @"Error calling AudioQueueNewInput";
        error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                           code:osStatusCode
                                       userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
        reject([@(osStatusCode) stringValue], errorMsg, error);
        return;
    }
    
    
    for (int i = 0; i < kNumberBuffers; i++) {
        osStatusCode = AudioQueueAllocateBuffer(_rxState.queue, //inAQ
                                                _rxState.frameBufferSize, //inBufferByteSize
                                                &_rxState.buffers[i]); //outBuffer
        if (osStatusCode) {
            NSString* errorMsg = @"Error calling AudioQueueAllocateBuffer";
            error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                               code:osStatusCode
                                           userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
            reject([@(osStatusCode) stringValue], errorMsg, error);
            return;
        }
        
        osStatusCode = AudioQueueEnqueueBuffer(_rxState.queue, _rxState.buffers[i], 0, NULL);
        if (osStatusCode) {
            NSString* errorMsg = @"Error calling AudioQueueEnqueueBuffer";
            error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                               code:osStatusCode
                                           userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
            RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
            reject([@(osStatusCode) stringValue], errorMsg, error);
            return;
        }
    }
        
    osStatusCode = AudioQueueStart(_rxState.queue, NULL);
    if (osStatusCode) {
        NSString* errorMsg = @"Error calling AudioQueueStart";
        error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                           code:osStatusCode
                                       userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
        reject([@(osStatusCode) stringValue], errorMsg, error);
        return;
    }
    
    RCTLogInfo(@"YeS!");
    resolve(@YES);
    return;
}


RCT_REMAP_METHOD(stop,
                 stopWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
    RCTLogInfo(@"stop");
    
    OSStatus osStatusCode = [_rxState.self handleStopDueTo: STOP_CODE_USER_REQUEST];
    if (osStatusCode) {
        NSString* errorMsg = @"Error calling handleStopDueTo";
        NSError* error = [[NSError alloc] initWithDomain:NSOSStatusErrorDomain
                                                    code:osStatusCode
                                                userInfo:@{NSLocalizedDescriptionKey: errorMsg}];
        RCTLogInfo(@"%@. Result code: %d", errorMsg, osStatusCode);
        reject([@(osStatusCode) stringValue], errorMsg, error);
        return;
    }
    
    resolve(@YES);
}


- (OSStatus) handleStopDueTo: (NSString*) stopCode {
    
    OSStatus osStatusCode1 = 0;
    OSStatus osStatusCode2 = 0;
    OSStatus osStatusCode3 = 0;
    
    if (_rxState.isReceiving) {
        _rxState.isReceiving = false;
        osStatusCode1 = AudioQueueStop(_rxState.queue, true);
        osStatusCode2 = AudioQueueDispose(_rxState.queue, true);
        if (_rxState.recordToFile) {
            osStatusCode3 = AudioFileClose(_rxState.recordingFileId);
        }
    }
        
    [_rxState.self sendEventWithName:stopEvent body:@{@"code":stopCode, @"filePath":_filePath ? _filePath : FILE_PATH_NA}];
    
    if (_rxState.recordToFile) {
        unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
        RCTLogInfo(@"file path %@", _filePath);
        RCTLogInfo(@"file size %llu", fileSize);
    }
    
    if (osStatusCode1) {
        return osStatusCode1;
    }
    if (osStatusCode2) {
        return osStatusCode2;
    }
    if (osStatusCode3) {
        return osStatusCode3;
    }
    return 0;
}


void HandleInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc) {
    
    AQRecordState* rs = (AQRecordState *)inUserData;
    bool isFinalBuffer = false;
  
    if (!rs->isReceiving) {
        return;
    }
    
    //If we're reaching the max number of samples...
    int32_t numFrameSamplesToProcess = inBuffer->mAudioDataByteSize / rs->format.mBytesPerPacket;
    if (rs->numSamplesProcessed + numFrameSamplesToProcess > rs->maxNumSamples) {
        isFinalBuffer = true;
        numFrameSamplesToProcess = rs->maxNumSamples - rs->numSamplesProcessed;
    }
    
    if (rs->recordToFile) {
        int result = AudioFileWritePackets(rs->recordingFileId,
                                           false,
                                           numFrameSamplesToProcess * rs->format.mBytesPerPacket,
                                           inPacketDesc,
                                           rs->currentPacket,
                                           &inNumPackets,
                                           inBuffer->mAudioData);
        if (result == noErr) {
            rs->currentPacket += inNumPackets;
        }
        else {
            [rs->self handleStopDueTo: STOP_CODE_ERROR];
        }
    }

    int64_t frameDataSize = inBuffer->mAudioDataByteSize;
    uint8_t* frameData = (uint8_t*) inBuffer->mAudioData;
    
    if (rs->reportFrameData) {
        NSData *data = [NSData dataWithBytes:frameData length:frameDataSize];
        NSString *dataStr = [data base64EncodedStringWithOptions:0];
        [rs->self sendEventWithName:frameDataEvent body:dataStr];
    }
    
    if (rs->reportVolume) {
        double volume = [rs->self calcVolumeFromBuffer:frameData ofSize:frameDataSize];
        [rs->self sendEventWithName:volumeEvent body:@(volume)];
    }
  
    AudioQueueEnqueueBuffer(rs->queue, inBuffer, 0, NULL);
    
    rs->numSamplesProcessed += numFrameSamplesToProcess;
    
    if (isFinalBuffer) {
        [rs->self handleStopDueTo:STOP_CODE_MAX_NUM_SAMPLES_REACHED];
    }
}


- (NSArray<NSString *> *)supportedEvents {
    return @[frameDataEvent,
             volumeEvent,
             stopEvent];
}


- (void)dealloc {
    RCTLogInfo(@"dealloc");
    AudioQueueDispose(_rxState.queue, true);
}


- (double) calcVolumeFromBuffer: (uint8_t*) buffer ofSize: (uint64_t) numBytes {

    // * Output in dBFS: dB relative to full scale
    // * Only includes contributions from the first channel
    
    uint32_t byteDepth = _rxState.format.mBitsPerChannel / 8;
    uint32_t numChannels = _rxState.format.mChannelsPerFrame;
    uint64_t numSamples = numBytes / (byteDepth * numChannels);
        
    double sumVolume = 0.0;
    double avgVolume = 0.0;
    if (byteDepth == 2) {
        int16_t* bufferInt16 = (int16_t*) buffer;
        for (int i=0; i<numSamples; i++) {
            double s = abs(bufferInt16[i * numChannels]);
            sumVolume += s;
        }
    }
    else {
        for (int i = 0; i < numSamples; i++) {
            double s = fabs((double)(buffer[i * numChannels]) - 127.0);
            sumVolume += s;
        }
    }
    
    avgVolume = sumVolume / numSamples;
    avgVolume /= (byteDepth == 1) ? (double)SCHAR_MAX : (double)SHRT_MAX;
    
    double dbFS = (avgVolume > 0.0) ? 20 * log10(avgVolume) : 0.0; //In case frame held all 0s...
    if (dbFS < MIN_VOLUME) {
        dbFS = MIN_VOLUME;
    }
    if (dbFS > MAX_VOLUME) {
        dbFS = MAX_VOLUME;
    }
    
    return dbFS;
}



@end

