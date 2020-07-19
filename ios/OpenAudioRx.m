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


/*
  
 Mostly, want:
 
 RESULT_OK = 0
 RESULT_ERR_INIT
 RESULT_ERR_INIT_SAMPLE_RATE - Can detect based on received value... Is this good enough?
 RESULT_ERR_INIT_BYTE_DEPTH ?
 RESULT_ERR_INIT_NUM_CHANNELS 1 or 2
 RESULT_ERR_INIT_MAX_DURATION Can do something reasonable. Only positive, etc...
 RESULT_ERR_START
 RESULT_ERR_STOP
 
 ....
  
 */


RCT_EXPORT_MODULE()


RCT_REMAP_METHOD(init,
                 ops:(NSDictionary *)ops
                 initWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {

    RCTLogInfo(@"init()");

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
    
    bool result = setupAVAudioSession(sampleRate);
    if (!result) {
        RCTLogInfo(@"Problem while setting up AVAudioSession");
        resolve(@NO);
        return;
    }
    
    RCTLogInfo(@"Sample Rate: %.0f", sampleRate);
    RCTLogInfo(@"Byte Depth: %d", byteDepth);
    RCTLogInfo(@"numChannels: %d", numChannels);
    RCTLogInfo(@"maxNumSamples: %d", maxNumSamples);
    RCTLogInfo(@"reportFrameData: %@", reportFrameData ? @"true" : @"false");
    RCTLogInfo(@"reportVolume: %@", reportVolume ? @"true" : @"false");
    RCTLogInfo(@"recordToFile: %@", recordToFile ? @"true" : @"false");
    RCTLogInfo(@"frameBufferSize: %d", _rxState.frameBufferSize);
    RCTLogInfo(@"filePath: %@", _filePath);
    
    resolve(@YES);
    return;
}


RCT_REMAP_METHOD(start,
                 startWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {

    RCTLogInfo(@"start()");

    OSStatus osStatus = noErr;
        
    _rxState.isReceiving = true;
    _rxState.currentPacket = 0;
    _rxState.numSamplesProcessed = 0;
  
    if (_rxState.recordToFile) {
        
        CFURLRef url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)_filePath, NULL);
        
        osStatus = AudioFileCreateWithURL(url,
                                          kAudioFileWAVEType,
                                          &_rxState.format,
                                          kAudioFileFlags_EraseFile,
                                          &_rxState.recordingFileId);
        if (osStatus) {
            RCTLogInfo(@"Error: Problem creating audio file.");
            resolve(@NO);
            return;
        }
        
        if (url) {
            CFRelease(url);
        }
    }
      
    osStatus = AudioQueueNewInput(&_rxState.format, //inFormat
                                  HandleInputBuffer, //inCallbackProc
                                  &_rxState, //inUserData
                                  NULL, //inCallbackRunLoop
                                  NULL, //inCallbackRunLoopMode
                                  0, //inFlags
                                  &_rxState.queue); //outAQ
    if (osStatus) {
        RCTLogInfo(@"Error: Problem creating audio queue.");
        resolve(@NO);
        return;
    }
    
    for (int i = 0; i < kNumberBuffers; i++) {
        
        osStatus = AudioQueueAllocateBuffer(_rxState.queue, //inAQ
                                            _rxState.frameBufferSize, //inBufferByteSize
                                            &_rxState.buffers[i]); //outBuffer
        if (osStatus) {
            RCTLogInfo(@"Error: Problem allocating audio queue buffer.");
            resolve(@NO);
            return;
        }
        
        osStatus = AudioQueueEnqueueBuffer(_rxState.queue, _rxState.buffers[i], 0, NULL);
        if (osStatus) {
            RCTLogInfo(@"Error: Problem enqueueing buffer.");
            resolve(@NO);
            return;
        }
    }
        
    osStatus = AudioQueueStart(_rxState.queue, NULL);
    if (osStatus) {
        RCTLogInfo(@"Error: Problem starting audio queue.");
        resolve(@NO);
        return;
    }
    
    resolve(@YES);
    return;
}


RCT_REMAP_METHOD(stop,
                 stopWithResolver:(RCTPromiseResolveBlock)resolve
                 rejecter:(RCTPromiseRejectBlock)reject) {
    
    RCTLogInfo(@"stop()");
    
    OSStatus osStatus = noErr;
    
    osStatus = [_rxState.self handleStopDueTo: STOP_CODE_USER_REQUEST];
    if (osStatus) {
        RCTLogInfo(@"Error: Problem handling user stop request.");
        resolve(@NO);
        return;
    }
        
    resolve(@YES);
    return;
}


- (OSStatus) handleStopDueTo: (NSString*) stopCode {
    
    RCTLogInfo(@"handleStopDueTo()");
    
    OSStatus osStatus = noErr;
    
    if (_rxState.isReceiving) {
        _rxState.isReceiving = false;
        
        osStatus = AudioQueueStop(_rxState.queue, true);
        if (osStatus) {
            RCTLogInfo(@"Error: Problem stopping audio queue.");
            return osStatus;
        }
        
        osStatus = AudioQueueDispose(_rxState.queue, true);
        if (osStatus) {
            RCTLogInfo(@"Error: Problem disposing of audio queue.");
            return osStatus;
        }
        
        if (_rxState.recordToFile) {
            osStatus = AudioFileClose(_rxState.recordingFileId);
            if (osStatus) {
                RCTLogInfo(@"Error: Problem closing audio file.");
                return osStatus;
            }
        }
    }
    
    [_rxState.self sendEventWithName:stopEvent body:@{@"code":stopCode, @"filePath":_filePath ? _filePath : FILE_PATH_NA}];
    
    if (_rxState.recordToFile) {
        unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:_filePath error:nil] fileSize];
        RCTLogInfo(@"file path %@", _filePath);
        RCTLogInfo(@"file size %llu", fileSize);
    }
    
    return noErr;
}


static bool setupAVAudioSession(double desiredSampleRate) {

    RCTLogInfo(@"setupAVAudioSession()");
    
    AVAudioSession* avAudioSession = [AVAudioSession sharedInstance];
    bool result = true;
    NSError* error = nil;
    
    //Set up audio session
    //++++++++++++
    //Deactivate session to request preferences
    if (!deactivateAudioSession()) {
        RCTLogInfo(@"Error deactivating session during setup.");
        return false;
    }
    
    //Set category
    //NOTE: AVAudioSessionCategoryRecord...
    // * Silences playback audio
    // * Had issues when I was testing on iPhone5  iOS 7 and 9
    error = nil;
    result = [avAudioSession setCategory: AVAudioSessionCategoryPlayAndRecord error: &error];
    if (!result) {
        RCTLogInfo(@"Error while setting category: %ld, %@", (long)error.code, error.localizedDescription);
        return false;
    }
    
    //Set mode
    //NOTE: AVAudioSessionModeMeasurement...
    // * Supposedly results in use of primary built-in mic.
    // * May affect audio output on iPad 4 (and other devices)?
    error = nil;
    result = [avAudioSession setMode: AVAudioSessionModeMeasurement error: &error];
    if (!result) {
        RCTLogInfo(@"Error while setting mode: %ld, %@", (long)error.code, error.localizedDescription);
        return false;
    }
    	
	//***** PREFERRED BUFFER DURATION AND SAMPLE RATE... ****
    
    //setPreferredIOBufferDuration
    NSTimeInterval preferredInputIOBufferDuration = 0.005f; //5ms
    error = nil;
    result = [avAudioSession setPreferredIOBufferDuration: preferredInputIOBufferDuration error: &error];
    if (!result) {
        RCTLogInfo(@"Error while setting buffer duration: %ld, %@", (long)error.code, error.localizedDescription);
        return false;
    }
    
    //setPreferredSampleRate - HW sample rate; impacts - but is not same as - SW sample rate
    RCTLogInfo(@"Requested hardware sample rate: %.0f", desiredSampleRate);
    double preferredInputHWSampleRate = desiredSampleRate;
    error = nil;
    result = [avAudioSession setPreferredSampleRate:preferredInputHWSampleRate error:&error];
    if (!result) {
        RCTLogInfo(@"Error while setting sample rate: %ld, %@", (long)error.code, error.localizedDescription);
        return false;
    }
    RCTLogInfo(@"Received hardware sample rate: %.0f", avAudioSession.sampleRate);
    
    //setPreferredInput and Data Source
    //++++
    NSArray *availableInputs = [avAudioSession availableInputs];
    AVAudioSessionPortDescription* builtInMicPort = nil;
    for (AVAudioSessionPortDescription* port in availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            builtInMicPort = port;
            break;
        }
    }
    if (!builtInMicPort) {
        RCTLogInfo(@"Device has no built-in mic port.");
        return false;
    }
    
    // Print out a description of the data sources for the built-in microphone
    //RCTLogInfo(@"There are %u data sources for port :'%@'", (unsigned)[builtInMicPort.dataSources count], builtInMicPort.portName);
    //RCTLogInfo(@"%@", builtInMicPort.dataSources);
    
    // loop over the built-in mic's data sources and attempt to locate the front microphone
    AVAudioSessionDataSourceDescription* frontInputDataSource = nil;
    for (AVAudioSessionDataSourceDescription* source in builtInMicPort.dataSources) {
        if ([source.orientation isEqual:AVAudioSessionOrientationFront]) {
            frontInputDataSource = source;
            break;
        }
    }
    if (frontInputDataSource) {
        
        /*
        RCTLogInfo(@"Currently selected audio source is '%@' for port '%@'",
                   builtInMicPort.selectedDataSource.dataSourceName,
                   builtInMicPort.portName);
        
        RCTLogInfo(@"Attempting to select audio source '%@' on port '%@'",
                   frontInputDataSource.dataSourceName,
                   builtInMicPort.portName);
        */
        
        // Set a preference for the front data source.
        error = nil;
        result = [builtInMicPort setPreferredDataSource: frontInputDataSource error: &error];
        if (!result) {
            RCTLogInfo(@"setPreferredDataSource input failed: %ld, %@",
                       (long) error.code,
                       error.localizedDescription);
            return false;
        }
    }
    
    // Set the built-in mic to be the selected for input.
    error = nil;
    result = [avAudioSession setPreferredInput: builtInMicPort error: &error];
    if (!result) {
        RCTLogInfo(@"setPreferred input failed: %ld, %@",
                   (long) error.code,
                   error.localizedDescription);
        return false;
    }
    //----
    //------------
    
    
    //Set up notification handlers
    //++++++++++++
    //See: http://stackoverflow.com/questions/20736809/avplayer-handle-when-incoming-call-come
    //For any interruption which would be called because of an incoming call, alarm clock, etc.
    
    NSNotificationCenter* notificationCenter = [NSNotificationCenter defaultCenter];
    /*
    //Interruption
    [notificationCenter removeObserver: audioControllerObjCpp
                                  name: AVAudioSessionInterruptionNotification
                                object: nil];

    [notificationCenter addObserver: audioControllerObjCpp
                           selector: @selector(handleAudioSessionInterruption:)
                               name: AVAudioSessionInterruptionNotification
                             object: avAudioSession];
    
    //Route change
    [notificationCenter removeObserver: audioControllerObjCpp
                                  name: AVAudioSessionRouteChangeNotification
                                object: nil];
    
    [notificationCenter addObserver: audioControllerObjCpp
                           selector: @selector(handleRouteChange:)
                               name: AVAudioSessionRouteChangeNotification
                             object: avAudioSession];
    
    //Media services reset
    [notificationCenter removeObserver: audioControllerObjCpp
                                  name: AVAudioSessionMediaServicesWereResetNotification
                                object: nil];
    
    [notificationCenter addObserver: audioControllerObjCpp
                           selector: @selector(handleMediaServicesReset)
                               name: AVAudioSessionMediaServicesWereResetNotification
                             object: avAudioSession];
    */
     //------------
    
    
    //Activate session (to verify that settings have taken effect)
    //NOTES: Activate AFTER requesting preferences, and BEFORE determining if preferences were granted
    if (!activateAudioSession()) {
        RCTLogInfo(@"Unable to activate audio session to test requested settings");
        return false;
    }
    
    
    //Verify audio session's configuration (session must be active)
    //++++++++++++
    //Determine whether preferences were granted or not
    //Sample Rate
    double grantedInputSampleRate = avAudioSession.sampleRate;
    if (grantedInputSampleRate != preferredInputHWSampleRate) {
        RCTLogInfo(@"Preferred input sample rate %.0f not granted. Sample rate: %.0f",
                   preferredInputHWSampleRate,
                   grantedInputSampleRate);
    }
    
    //Buffer Duration
    NSTimeInterval grantedInputIOBufferDuration = avAudioSession.IOBufferDuration;
    if (grantedInputIOBufferDuration != preferredInputIOBufferDuration) {
        RCTLogInfo(@"Preferred buffer duration %.4f not granted. Actual buffer duration: %.4f",
                   preferredInputIOBufferDuration,
                   grantedInputIOBufferDuration);
    }
    
    //Buffer Size
    uint32_t grantedInputIOBufferLength =
        round(grantedInputIOBufferDuration * grantedInputSampleRate);
    RCTLogInfo(@"Granted buffer length: %d", grantedInputIOBufferLength);
    
    
    //Input Data Source
    AVAudioSessionDataSourceDescription* inputDataSource = avAudioSession.inputDataSource;
    if (frontInputDataSource && inputDataSource) { //Both would be nil if switching between inputs is not possible on a given device
        if (![inputDataSource.dataSourceID isEqualToNumber: frontInputDataSource.dataSourceID]) {
            
            RCTLogInfo(@"Preferred audio data source: ('%@', %@) not granted",
                       frontInputDataSource.dataSourceName,
                       [frontInputDataSource.dataSourceID stringValue]);

            RCTLogInfo(@"Currently selected source is: '%@', %@.",
                       inputDataSource.dataSourceName,
                       [inputDataSource.dataSourceID stringValue]);
        }
    }
    //Loop over built-in mic's data sources and attempt to locate the input data source
    bool inputDataSourceIsBuiltIn = false;
    for (AVAudioSessionDataSourceDescription* source in builtInMicPort.dataSources) {
        if ([source.dataSourceID isEqualToNumber: inputDataSource.dataSourceID]) {
            inputDataSourceIsBuiltIn = true;
            break;
        }
    }
    if (!inputDataSourceIsBuiltIn) {
        RCTLogInfo(@"Currently selected source is NOT a built-in source.");
    }
    //------------
    
    
    //Set microphone gain (while session is active), if possible
    //++++++++++++
    float gain = [avAudioSession inputGain];
    RCTLogInfo(@"Initial microphone gain: %.2f", gain);
    
    if ([avAudioSession isInputGainSettable]) {
        result = [avAudioSession setInputGain: 1.0f error: &error]; //Highest value is 1.0
        if (!result) {
            RCTLogInfo(@"Error while setting microphone input gain.");
            return false;
        }
    }
    else {
        RCTLogInfo(@"Microphone input gain for this device is not settable.");
    }
    
    gain = [avAudioSession inputGain];
    RCTLogInfo(@"Microphone gain after configuration: %.2f", gain);
    //-----------
    
    /*
    //Deactivate session (now that we know whether or not settings have taken effect)
    if (!deactivateAudioSession()) {
        RCTLogInfo(@"Unable to deactivate audio session after checking requestes settings");
        return false;
    }
    
    //Activate the audio session
     if (!activateAudioSession()) {
        RCTLogInfo(@"Unable to activate audio session after checking requested settings");
        return false;
     }
     */
    
    return true;
}



bool activateAudioSession() {
    AVAudioSession* avAudioSession = [AVAudioSession sharedInstance];
    NSError* error = nil;
    bool result = [avAudioSession setActive: YES error: &error];
    if (!result) {
        RCTLogInfo(@"Error activating avAudioSession: %ld, %@",
                   (long)error.code,
                   error.localizedDescription);
    }
    
    return result;
}



static bool deactivateAudioSession() {
    AVAudioSession* avAudioSession = [AVAudioSession sharedInstance];
    NSError* error = nil;
    bool result = [avAudioSession setActive: NO error: &error];
    if (!result) {
        RCTLogInfo(@"Error deactivating avAudioSession: %ld, %@",
                   (long)error.code,
                   error.localizedDescription);
    }
    
    return result;
}



void HandleInputBuffer(void *inUserData,
                       AudioQueueRef inAQ,
                       AudioQueueBufferRef inBuffer,
                       const AudioTimeStamp *inStartTime,
                       UInt32 inNumPackets,
                       const AudioStreamPacketDescription *inPacketDesc) {
    
    OSStatus osStatus = noErr;
    
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
        osStatus = AudioFileWritePackets(rs->recordingFileId,
                                         false,
                                         numFrameSamplesToProcess * rs->format.mBytesPerPacket,
                                         inPacketDesc,
                                         rs->currentPacket,
                                         &inNumPackets,
                                         inBuffer->mAudioData);
        if (osStatus) {
            [rs->self handleStopDueTo: STOP_CODE_ERROR];
            // *** RETURN HERE?
        }
        else {
            rs->currentPacket += inNumPackets;
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
  
    osStatus = AudioQueueEnqueueBuffer(rs->queue, inBuffer, 0, NULL);
    if (osStatus) {
        RCTLogInfo(@"Error: Problem enqueueing buffer");
    }
    
    rs->numSamplesProcessed += numFrameSamplesToProcess;
    
    if (isFinalBuffer) {
        osStatus = [rs->self handleStopDueTo: STOP_CODE_MAX_NUM_SAMPLES_REACHED];
        if (osStatus) {
            RCTLogInfo(@"Error: Problem handling stop due to max num samples reached");
        }
    }
}


- (NSArray<NSString *> *)supportedEvents {
    return @[frameDataEvent,
             volumeEvent,
             stopEvent];
}


- (void) dealloc {
    RCTLogInfo(@"dealloc()");
        
    OSStatus osStatus = AudioQueueDispose(_rxState.queue, true);
    if (osStatus) {
        RCTLogInfo(@"Error: Problem disposing of audio queue");
    }
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

