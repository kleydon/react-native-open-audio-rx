import { NativeModules, NativeEventEmitter } from 'react-native';
const RNOpenAudioRx = NativeModules.OpenAudioRx;
const EventEmitter = new NativeEventEmitter(RNOpenAudioRx);

const OpenAudioRx = {};

OpenAudioRx.init = (options) => RNOpenAudioRx.init(options);
OpenAudioRx.start = () => RNOpenAudioRx.start();
OpenAudioRx.stop = () => RNOpenAudioRx.stop();

const eventsMap = {
  frameDataEvent: 'frameDataEvent',
  volumeEvent: 'volumeEvent',
  stopEvent: 'stopEvent',
};

OpenAudioRx.subscribe = (event, callback) => {
  const nativeEvent = eventsMap[event];
  if (!nativeEvent) {
    throw new Error('Invalid event');
  }
  EventEmitter.removeAllListeners(nativeEvent);
  return EventEmitter.addListener(nativeEvent, callback);
};

export default OpenAudioRx;
