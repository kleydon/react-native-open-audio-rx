#import <AVFoundation/AVFoundation.h>
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>



#define kNumberBuffers 3

typedef struct {
    __unsafe_unretained id      self; //OpenAudioRx instance
    bool                        isReceiving;
    UInt32                      numSamplesProcessed;
    UInt32                      maxNumSamples;
    AudioStreamBasicDescription format;
    AudioQueueRef               queue;
    AudioQueueBufferRef         buffers[kNumberBuffers];
    UInt32                      frameBufferSize; //In bytes
    bool                        reportFrameData;
    bool                        reportVolume;
    SInt64                      currentPacket;
    bool                        recordToFile;
    AudioFileID                 recordingFileId;
} AQRecordState;


@interface OpenAudioRx : RCTEventEmitter <RCTBridgeModule>
    @property (nonatomic, assign) AQRecordState rxState;
    @property (nonatomic, strong) NSString* filePath;
@end

