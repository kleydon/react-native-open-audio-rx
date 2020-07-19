package com.quixo3.OpenAudioRx;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder.AudioSource;
import android.media.audiofx.AutomaticGainControl;
import android.util.Base64;
import android.util.Log;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule.RCTDeviceEventEmitter;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;


public class OpenAudioRxModule extends ReactContextBaseJavaModule {

    private final String LOG_TAG = "RNOpenRx";
    private final ReactApplicationContext reactContext;
    private RCTDeviceEventEmitter eventEmitter;

    private final String frameDataEvent = "frameDataEvent";
    private final String volumeEvent = "volumeEvent";
    private final String stopEvent = "stopEvent";

    private final String STOP_CODE_USER_REQUEST = "STOP_CODE_USER_REQUEST";
    private final String STOP_CODE_MAX_NUM_SAMPLES_REACHED = "STOP_CODE_MAX_NUM_SAMPLES_REACHED";
    private final String STOP_CODE_ERROR = "STOP_CODE_ERROR";
    private String stopCode;

    private final String  FILE_PATH_NA = "FILE_PATH_NA";

    private final double MAX_VOLUME = 0;
    private final double MIN_VOLUME = -100;

    private final int DEFAULT_MAX_DURATION = 10; //Seconds

    private int sampleRate;
    private int numChannels;
    private int byteDepth;
    private int maxNumSamples;

    private boolean reportVolume;
    private boolean reportFrameData;
    private boolean recordToFile;

    private AudioRecord audioRecord;
    private int frameBufferSize;
    private boolean isRunning;

    private String tempRawPCMDataFilePath;
    private String outputWavFilePath;



    public OpenAudioRxModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }


    @Override
    public String getName() {
        return "OpenAudioRx";
    }


    @ReactMethod
    public void init(ReadableMap options, Promise promise) {

        final String sampleRateKey = "sampleRate";
        final String numChannelsKey = "numChannels";
        final String byteDepthKey = "byteDepth";
        final String maxDurationKey = "maxDuration";  //Seconds
        final String reportFrameDataKey = "reportFrameData";
        final String reportVolumeKey = "reportVolume";
        final String recordToFileKey = "recordToFile";
        final String audioSourceKey = "audioSource";

        sampleRate = 44100;
        if (options.hasKey(sampleRateKey)) {
            sampleRate = options.getInt(sampleRateKey);
        }

        numChannels = 1;
        if (options.hasKey(numChannelsKey)) {
            if (options.getInt(numChannelsKey) == 2) {
                numChannels = 2;
            }
        }

        byteDepth = 2;
        if (options.hasKey(byteDepthKey)) {
            if (options.getInt(byteDepthKey) == 1) {
                byteDepth = 1;
            }
        }

        maxNumSamples = sampleRate * DEFAULT_MAX_DURATION;
        if (options.hasKey(maxDurationKey)) {
            maxNumSamples =  sampleRate * options.getInt(maxDurationKey);
        }

        reportVolume = false;
        if (options.hasKey(reportVolumeKey)) {
            reportVolume = options.getBoolean(reportVolumeKey);
        }

        reportFrameData = false;
        if (options.hasKey(reportFrameDataKey)) {
            reportFrameData = options.getBoolean(reportFrameDataKey);
        }

        recordToFile = true;
        if (options.hasKey(recordToFileKey)) {
            recordToFile = options.getBoolean(recordToFileKey);
        }

        int audioSource = AudioSource.VOICE_RECOGNITION;
        if (options.hasKey(audioSourceKey)) {
            audioSource = options.getInt(audioSourceKey);
        }

        tempRawPCMDataFilePath = null;
        outputWavFilePath = null;
        if (recordToFile) {
            String dirPath = getReactApplicationContext().getFilesDir().getAbsolutePath();
            tempRawPCMDataFilePath = dirPath + "/" + "temp.pcm";
            outputWavFilePath = dirPath + "/" + "react-native-open-rx.wav";
        }

        isRunning = false;
        eventEmitter = reactContext.getJSModule(RCTDeviceEventEmitter.class);

        int minframeBufferSize = AudioRecord.getMinBufferSize(sampleRate, getChannelConfig(), getAudioFormat());
        frameBufferSize = minframeBufferSize * 2;
        audioRecord = new AudioRecord(audioSource, sampleRate, getChannelConfig(), getAudioFormat(), frameBufferSize);

        if (AutomaticGainControl.isAvailable()) {
            AutomaticGainControl agc = AutomaticGainControl.create(
                    audioRecord.getAudioSessionId()
            );
            agc.setEnabled(false);
        }

        Log.d(LOG_TAG, "sampleRate: "+ sampleRate);
        Log.d(LOG_TAG, "numChannels: "+ numChannels);
        Log.d(LOG_TAG, "byteDepth: "+ byteDepth);
        Log.d(LOG_TAG, "maxNumSamples: "+ maxNumSamples);
        Log.d(LOG_TAG, "reportVolume: "+ reportVolume);
        Log.d(LOG_TAG, "reportFrameData: "+ reportFrameData);
        Log.d(LOG_TAG, "recordToFile: "+ recordToFile);
        Log.d(LOG_TAG, "audioSource: "+ audioSource);
        Log.d(LOG_TAG, "frameBufferSize: "+ frameBufferSize);
        Log.d(LOG_TAG, "filePath: "+ outputWavFilePath);

        promise.resolve(true);
        return;
    }


    @ReactMethod
    public void start(Promise promise) {

        isRunning = true;
        stopCode = STOP_CODE_USER_REQUEST; //Assume the best

        audioRecord.startRecording();

        Log.d(LOG_TAG, "started recording");

        Thread rxThread = new Thread(new Runnable() {

            public void run() {

                FileOutputStream fos = null;
                try {
                    int bytesRead = 0;
                    int frameCount = 0;
                    int numSamplesProcessed = 0;
                    byte[] frameData = new byte[frameBufferSize];

                    if (recordToFile) {
                        fos = new FileOutputStream(tempRawPCMDataFilePath);
                    }

                    while (isRunning) {

                        bytesRead = audioRecord.read(frameData, 0, frameData.length);
                        if (bytesRead > 0 && ++frameCount > 2) { // skip first 2, to eliminate "click sound"

                            int bytesPerPacket = byteDepth * numChannels;
                            int numSamplesToProcess = bytesRead / bytesPerPacket;
                            if (numSamplesProcessed + numSamplesToProcess > maxNumSamples) {
                                numSamplesToProcess = maxNumSamples - numSamplesProcessed;
                                isRunning = false;
                                stopCode = STOP_CODE_MAX_NUM_SAMPLES_REACHED;
                            }

                            if (reportFrameData) {
                                String base64Data = Base64.encodeToString(frameData, Base64.NO_WRAP);
                                eventEmitter.emit(frameDataEvent, base64Data);
                            }

                            if (reportVolume) {
                                double volume = calcVolume(frameData);
                                eventEmitter.emit(volumeEvent, volume);
                            }

                            if (recordToFile) {
                                fos.write(frameData, 0, numSamplesToProcess * bytesPerPacket);
                            }

                            numSamplesProcessed += numSamplesToProcess;
                        }
                    }

                    audioRecord.stop();

                    if (recordToFile) {
                        fos.close();
                        saveAsWav();
                    }
                }
                catch (Exception e) {
                    e.printStackTrace();
                    stopCode = STOP_CODE_ERROR;
                }
                finally {

                    if (fos != null) {
                        try {
                            fos.close();
                        } catch (Exception e) {
                            e.printStackTrace();
                            stopCode = STOP_CODE_ERROR;
                        }
                    }

                    if (recordToFile) {
                        deleteTempFile();
                    }

                    emitStopEvent(stopCode);
                }
            }
        });

        rxThread.start();

        promise.resolve(true);
        return;
    }


    @ReactMethod
    public void stop(Promise promise) {

        Log.d(LOG_TAG, "stop().");

        stopCode = STOP_CODE_USER_REQUEST;
        isRunning = false;

        //Note: emitStopEvent() gets called via recordThread

        promise.resolve(true);
        return;
    }


    private void emitStopEvent(String stopCode) {

        Log.d(LOG_TAG, "handleStop().");

        WritableMap params = Arguments.createMap();
        params.putString("code", stopCode);
        params.putString("filePath", (outputWavFilePath != null) ? outputWavFilePath : FILE_PATH_NA);

        eventEmitter.emit(stopEvent, params);
    }


    private double calcVolume(byte[] frameData) { //channels interleaved

        // * Output in dBFS: dB relative to full scale
        // * Only includes contributions of channel-1 samples

        double sumVolume = 0.0;
        double avgVolume = 0.0;
        int numBytes = frameData.length;
        int numSamples = numBytes / (byteDepth * numChannels);
        if (byteDepth == 2) {
            final short[] bufferInt16 = new short[numSamples * numChannels];
            final ByteBuffer byteBuffer = ByteBuffer.wrap(frameData, 0, numBytes);
            byteBuffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(bufferInt16);
            for (int i = 0; i < numSamples; i++) {
                sumVolume += Math.abs(bufferInt16[i * numChannels]);
            }
        }
        else {
            for (int i = 0; i < numSamples; i++) {
                int s = ((int)(0xFF & frameData[i * numChannels])) - 127;
                sumVolume +=  Math.abs((double)s);
            }
        }

        avgVolume = sumVolume / numSamples;
        avgVolume /= (byteDepth == 1) ? Byte.MAX_VALUE : Short.MAX_VALUE;

        double dbFS = (avgVolume > 0.0) ? 20 * Math.log10(avgVolume) : 0.0;
        if (dbFS < MIN_VOLUME) {
            dbFS = MIN_VOLUME;
        }
        if (dbFS > MAX_VOLUME) {
            dbFS = MAX_VOLUME;
        }

        return dbFS;
    }


    private void saveAsWav() throws Exception {

        if (tempRawPCMDataFilePath == null ||
            outputWavFilePath == null) {
            throw new Exception("saveAsWav() - Null file path.");
        }

        Log.d(LOG_TAG, "Saving " + outputWavFilePath + "...");

        FileInputStream fis = null;
        FileOutputStream fos = null;

        fis = new FileInputStream(tempRawPCMDataFilePath);
        fos = new FileOutputStream(outputWavFilePath);
        long numSampleDataBytes = fis.getChannel().size();

        addWavHeader(fos, numSampleDataBytes);

        //Add Wav data
        byte[] data = new byte[512];
        int bytesRead;
        while ((bytesRead = fis.read(data)) != -1) {
            Log.d(LOG_TAG, "Saving buffer...");
            fos.write(data, 0, bytesRead);
        }

        Log.d(LOG_TAG, "wav file path:" + outputWavFilePath);
        Log.d(LOG_TAG, "wav file size:" + fos.getChannel().size());

        Log.d(LOG_TAG, "Done save.");

        if (fis != null) {
            Log.d(LOG_TAG, "Closing fis.");
            fis.close();
        }
        if (fos != null) {
            Log.d(LOG_TAG, "Closing fos.");
            fos.close();
        }
    }


    private void addWavHeader(FileOutputStream fos, long numSampleDataBytes) throws Exception {

        long byteRate = sampleRate * numChannels * byteDepth;
        int blockAlign = numChannels * byteDepth;

        final int numHeaderBytes = 44;
        byte[] header = new byte[numHeaderBytes];
        long numWavFileBytesLess8 = numSampleDataBytes + numHeaderBytes - 8;

        header[0] = 'R';                                    // RIFF chunk
        header[1] = 'I';
        header[2] = 'F';
        header[3] = 'F';
        header[4] = (byte) (numWavFileBytesLess8 & 0xff);   //File Size, less 8 (for RIFF + file size)
        header[5] = (byte) ((numWavFileBytesLess8 >> 8) & 0xff);
        header[6] = (byte) ((numWavFileBytesLess8 >> 16) & 0xff);
        header[7] = (byte) ((numWavFileBytesLess8 >> 24) & 0xff);
        header[8] = 'W';                                    // WAVE chunk
        header[9] = 'A';
        header[10] = 'V';
        header[11] = 'E';
        header[12] = 'f';                                   // 'fmt ' chunk
        header[13] = 'm';
        header[14] = 't';
        header[15] = ' ';
        header[16] = 16;                                    // 4 bytes: size of 'fmt ' chunk
        header[17] = 0;
        header[18] = 0;
        header[19] = 0;
        header[20] = 1;                                     // format = 1 for PCM
        header[21] = 0;
        header[22] = (byte) (numChannels & 0xFF);                       // mono or stereo
        header[23] = 0;
        header[24] = (byte) (sampleRate & 0xff);            // samples per second
        header[25] = (byte) ((sampleRate >> 8) & 0xff);
        header[26] = (byte) ((sampleRate >> 16) & 0xff);
        header[27] = (byte) ((sampleRate >> 24) & 0xff);
        header[28] = (byte) (byteRate & 0xff);              // bytes per second
        header[29] = (byte) ((byteRate >> 8) & 0xff);
        header[30] = (byte) ((byteRate >> 16) & 0xff);
        header[31] = (byte) ((byteRate >> 24) & 0xff);
        header[32] = (byte) blockAlign;                     // bytes in one sample, for all channels
        header[33] = 0;
        header[34] = (byte) (byteDepth * 8);                  // bits in (one channel of a) sample
        header[35] = 0;
        header[36] = 'd';                                   // beginning of the data chunk
        header[37] = 'a';
        header[38] = 't';
        header[39] = 'a';
        header[40] = (byte) (numSampleDataBytes & 0xff);         // how big is this data chunk
        header[41] = (byte) ((numSampleDataBytes >> 8) & 0xff);
        header[42] = (byte) ((numSampleDataBytes >> 16) & 0xff);
        header[43] = (byte) ((numSampleDataBytes >> 24) & 0xff);

        fos.write(header, 0, 44);
    }


    /*
    private void getFileContentsAsB64(String filePath, String fileBytesB64) {

        FileInputStream ifs = null;
        try {
            ifs = new FileInputStream(filePath);

            int numFileBytes = (int) ifs.getChannel().size();
            byte[] fileBytes = new byte[numFileBytes];

            int bytesRead;
            byte[] bytes = new byte[512];
            int fileBytesIndex = 0;
            while ((bytesRead = ifs.read(bytes)) != -1) {
                for (int i = 0; i < bytesRead; i++) {
                    fileBytes[fileBytesIndex] = bytes[i];
                    fileBytesIndex++;
                }
            }

            if (fileBytesIndex != numFileBytes) {
                throw new Exception("File byte count mismatch.");
            }

            fileBytesB64 = Base64.encodeToString(fileBytes, Base64.NO_WRAP);

            Log.d(LOG_TAG, "getFileContentsAsB64()");
            Log.d(LOG_TAG, "  numFileBytes: " + numFileBytes);
            Log.d(LOG_TAG, "  numFileBytesB64: " + fileBytes.length);
            Log.d(LOG_TAG, "  fileBytesB64: " + fileBytesB64 + "<end>");
        }
        catch (Exception e) {
            e.printStackTrace();
        }
        finally {
            if (ifs != null) {
                try {
                    ifs.close();
                } catch (Exception e) {
                    e.printStackTrace();
                }
            }
        }
    }
*/

    private void deleteTempFile() {
        if (tempRawPCMDataFilePath != null) {
            File f = new File(tempRawPCMDataFilePath);
            f.delete();
        }
    }


    private int getChannelConfig() {
        return (numChannels == 2) ? AudioFormat.CHANNEL_IN_STEREO : AudioFormat.CHANNEL_IN_MONO;
    }


    private int getAudioFormat() {
        return (byteDepth == 2) ? AudioFormat.ENCODING_PCM_16BIT : AudioFormat.ENCODING_PCM_8BIT;
    }
}
