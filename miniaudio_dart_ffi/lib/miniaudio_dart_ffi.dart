// ignore_for_file: omit_local_variable_types

import "dart:ffi";
import "dart:typed_data";

import "package:ffi/ffi.dart";
import "package:miniaudio_dart_ffi/miniaudio_dart_ffi_bindings.dart"
    as bindings;
import "package:miniaudio_dart_platform_interface/miniaudio_dart_platform_interface.dart";

// dynamic lib
const String _libName = "miniaudio_dart_ffi";

MiniaudioDartPlatformInterface registeredInstance() => MiniaudioDartFfi();

class MiniaudioDartFfi extends MiniaudioDartPlatformInterface {
  MiniaudioDartFfi();

  @override
  PlatformEngine createEngine() {
    final eng = bindings.engine_alloc();
    if (eng == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }
    return FfiEngine(eng);
  }

  @override
  PlatformRecorder createRecorder() {
    final rec = bindings.recorder_create();
    if (rec == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }
    return FfiRecorder(rec);
  }

  @override
  PlatformConverter createConverter() {
    final converter = bindings.converter_create();

    if (converter == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }

    return FfiConverter(converter);
  }

  @override
  PlatformGenerator createGenerator() {
    final gen = bindings.generator_create();
    if (gen == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }
    return FfiGenerator(gen);
  }

  @override
  PlatformStreamPlayer createStreamPlayer({
    required PlatformEngine engine,
    required int format,
    required int channels,
    required int sampleRate,
    int bufferMs = 240,
  }) {
    final engWrapper = (engine as FfiEngine)._self;
    final sp = bindings.stream_player_alloc();
    if (sp == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }

    final cfgPtr = calloc<bindings.StreamPlayerConfig>();
    try {
      cfgPtr.ref
        ..formatAsInt = format
        ..channels = channels
        ..sampleRate = sampleRate
        ..bufferMilliseconds = bufferMs;

      final ok = bindings.stream_player_init_with_engine(
          sp, engWrapper.cast(), cfgPtr);
      if (ok != 1) {
        bindings.stream_player_free(sp);
        throw MiniaudioDartPlatformException("stream_player_init failed.");
      }
    } finally {
      calloc.free(cfgPtr);
    }

    return FfiStreamPlayer._(sp, channels);
  }

  @override
  PlatformMp3Encoder createMp3Encoder() {
    final enc = bindings.mp3_encoder_create();
    if (enc == nullptr) {
      throw MiniaudioDartPlatformOutOfMemoryException();
    }
    return FfiMp3Encoder(enc);
  }
}

class FfiMp3Encoder implements PlatformMp3Encoder {
  FfiMp3Encoder(Pointer<bindings.Mp3Encoder> self) : _self = self;

  final Pointer<bindings.Mp3Encoder> _self;
  bool _disposed = false;

  // MP3 frames are at most ~1441 bytes; give ourselves a generous margin.
  static const int _outCap = 1 << 16;

  @override
  bool init({
    required int sampleRate,
    required int channels,
    int bitrateKbps = 32,
  }) {
    return bindings.mp3_encoder_init(_self, sampleRate, channels, bitrateKbps) == 1;
  }

  @override
  Uint8List encode(Int16List pcm) {
    if (pcm.isEmpty) return Uint8List(0);

    final pcmPtr = calloc<Int16>(pcm.length);
    final outPtr = calloc<Uint8>(_outCap);
    try {
      pcmPtr.asTypedList(pcm.length).setAll(0, pcm);

      final written = bindings.mp3_encoder_encode_s16(
        _self,
        pcmPtr,
        pcm.length,
        outPtr,
        _outCap,
      );

      if (written <= 0) return Uint8List(0);
      return Uint8List.fromList(outPtr.asTypedList(written));
    } finally {
      calloc.free(pcmPtr);
      calloc.free(outPtr);
    }
  }

  @override
  Uint8List flush() {
    final outPtr = calloc<Uint8>(_outCap);
    try {
      final written = bindings.mp3_encoder_flush(_self, outPtr, _outCap);
      if (written <= 0) return Uint8List(0);
      return Uint8List.fromList(outPtr.asTypedList(written));
    } finally {
      calloc.free(outPtr);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bindings.mp3_encoder_destroy(_self);
  }
}

class FfiRecorder implements PlatformRecorder {
  FfiRecorder(Pointer<bindings.Recorder> self) : _self = self;

  final Pointer<bindings.Recorder> _self;
  int _channels = 0;
  int _format = 0;

  @override
  Future<void> initStream({
    int sampleRate = 48000,
    int channels = 1,
    int format = AudioFormat.float32,
    int bufferDurationSeconds = 5,
  }) async {
    final cfgPtr = calloc<bindings.RecorderConfig>();

    try {
      cfgPtr.ref
        ..sampleRate = sampleRate
        ..channels = channels
        ..formatAsInt = format
        ..bufferDurationSeconds = bufferDurationSeconds
        ..autoStart = 0;

      final ok = bindings.recorder_init(_self, cfgPtr);
      if (ok != 1) {
        throw MiniaudioDartPlatformException("Failed to initialize recorder.");
      }

      _channels = channels;
      _format = format;
    } finally {
      calloc.free(cfgPtr);
    }
  }

  dynamic _emptyPcm() {
    switch (_format) {
      case AudioFormat.int16:
        return Int16List(0);
      case AudioFormat.uint8:
        return Uint8List(0);
      case AudioFormat.float32:
      default:
        return Float32List(0);
    }
  }

  @override
  dynamic readChunk({int maxFrames = 512}) {
    if (_channels == 0) return _emptyPcm();

    final ptrOut = calloc<Pointer<Void>>();
    final framesOut = calloc<Int>();
    try {
      final ok =
          bindings.recorder_acquire_read_region(_self, ptrOut, framesOut);
      if (ok == 0) return _emptyPcm();

      final available = framesOut.value;
      if (available <= 0) return _emptyPcm();

      final use = available > maxFrames ? maxFrames : available;
      final dataPtr = ptrOut.value;
      if (dataPtr == nullptr) return _emptyPcm();

      dynamic result;
      switch (_format) {
        case AudioFormat.float32:
          final ptr = dataPtr.cast<Float>();
          result = Float32List.fromList(
            ptr.asTypedList(use * _channels),
          );
          break;

        case AudioFormat.int16:
          final ptr = dataPtr.cast<Int16>();
          result = Int16List.fromList(
            ptr.asTypedList(use * _channels),
          );
          break;

        case AudioFormat.uint8:
          final ptr = dataPtr.cast<Uint8>();
          result = Uint8List.fromList(
            ptr.asTypedList(use * _channels),
          );
          break;

        default:
          throw UnsupportedError(
            "Unsupported PCM format: $_format",
          );
      }

      bindings.recorder_commit_read_frames(_self, use);
      return result;
    } finally {
      calloc.free(ptrOut);
      calloc.free(framesOut);
    }
  }

  @override
  dynamic getBuffer(int framesToRead) =>
      framesToRead <= 0 ? _emptyPcm() : readChunk(maxFrames: framesToRead);

  @override
  void start() {
    if (_self == nullptr) return;
    final result = bindings.recorder_start(_self);
    if (result != 1) {
      throw MiniaudioDartPlatformException("Failed to start recorder");
    }
  }

  @override
  void stop() {
    if (_self == nullptr) return;
    final result = bindings.recorder_stop(_self);
    if (result != 1) {
      throw MiniaudioDartPlatformException("Failed to stop recorder");
    }
  }

  @override
  bool get isRecording {
    if (_self == nullptr) return false;
    return bindings.recorder_is_recording(_self) == 1;
  }

  @override
  int getAvailableFrames() {
    if (_self == nullptr) return 0;
    return bindings.recorder_get_available_frames(_self);
  }

  double _captureGain = 1.0;
  @override
  double get captureGain {
    if (_self == nullptr) return 1.0;
    return bindings.recorder_get_capture_gain(_self);
  }

  @override
  set captureGain(double value) {
    if (_self == nullptr) return;
    bindings.recorder_set_capture_gain(_self, value);
  }

  @override
  void dispose() => bindings.recorder_destroy(_self);

  @override
  Future<List<(String name, bool isDefault)>> enumerateCaptureDevices() async {
    final ok = bindings.recorder_refresh_capture_devices(_self);
    if (ok != 1) return [];

    final count = bindings.recorder_get_capture_device_count(_self);
    final devices = <(String, bool)>[];

    for (int i = 0; i < count; i++) {
      final namePtr = calloc<Char>(256);
      final isDefaultPtr = calloc<bindings.ma_bool32>();
      try {
        final success = bindings.recorder_get_capture_device_name(
            _self, i, namePtr, 256, isDefaultPtr);
        if (success == 1) {
          final name = namePtr.cast<Utf8>().toDartString();
          final isDefault = isDefaultPtr.value;
          devices.add((name, isDefault != 0));
        }
      } finally {
        calloc.free(namePtr);
        calloc.free(isDefaultPtr);
      }
    }
    return devices;
  }

  @override
  Future<bool> selectCaptureDeviceByIndex(int index) async {
    final ok = bindings.recorder_select_capture_device_by_index(_self, index);
    return ok == 1;
  }

  @override
  int getCaptureDeviceGeneration() =>
      bindings.recorder_get_capture_device_generation(_self);
}
class FfiConverter implements PlatformConverter {
  FfiConverter(Pointer<bindings.Converter> self) : _self = self;

  final Pointer<bindings.Converter> _self;

  int _inputSampleRate = 0;
  int _outputSampleRate = 0;
  int _channels = 0;
  int _format = 0;

  bool _initialized = false;

  @override
  Future<void> init({
    int inputSampleRate = 16000,
    int outputSampleRate = 24000,
    int channels = 1,
    int format = AudioFormat.int16,
  }) async {
    final cfgPtr = calloc<bindings.ConverterConfig>();

    try {
      cfgPtr.ref
        ..inputSampleRate = inputSampleRate
        ..outputSampleRate = outputSampleRate
        ..channels = channels
        ..formatAsInt = format;


      final ok = bindings.converter_init(_self, cfgPtr);


      if (ok != 1) {
        throw MiniaudioDartPlatformException(
            "Failed to initialize converter."
        );
      }


      _inputSampleRate = inputSampleRate;
      _outputSampleRate = outputSampleRate;
      _channels = channels;
      _format = format;

      _initialized = true;


    } finally {

      calloc.free(cfgPtr);

    }
  }



  @override
  Uint8List convert(Uint8List data) {
    if (!_initialized) {
      throw MiniaudioDartPlatformException("Converter is not initialized.");
    }


    if (data.isEmpty) {
      return Uint8List(0);
    }

    final bytesPerSample = _bytesPerSample(_format);


    final inputFrames = data.length ~/ (bytesPerSample * _channels);

    if (inputFrames <= 0) {
      return Uint8List(0);
    }

    /*
       Allocate output buffer.

       Example:
       16000 -> 24000

       512 frames input
       ~768 frames output
    */

    final ratio = _outputSampleRate / _inputSampleRate;

    final outputCapacityFrames = (inputFrames * ratio).ceil() + 32;

    final inputPtr = calloc<Uint8>(data.length);

    final outputPtr = calloc<Uint8>(outputCapacityFrames * _channels * bytesPerSample);

    try {
      inputPtr.asTypedList(data.length).setAll(0, data);

      final outputFrames =
      bindings.converter_process(
        _self,
        inputPtr.cast(),
        inputFrames,
        outputPtr.cast(),
        outputCapacityFrames,
      );

      if (outputFrames <= 0) {
        return Uint8List(0);
      }

      final outputBytes = outputFrames * _channels * bytesPerSample;

      return Uint8List.fromList(
        outputPtr
            .asTypedList(
          outputBytes,
        ),
      );
    } finally {
      calloc.free(inputPtr);
      calloc.free(outputPtr);
    }
  }

  int _bytesPerSample(int format) {
    switch(format) {
      case AudioFormat.uint8:
        return 1;
      case AudioFormat.int16:
        return 2;
      case AudioFormat.float32:
        return 4;
      default:
        throw UnsupportedError("Unsupported audio format: $format");
    }
  }

  @override
  void dispose() {
    bindings.converter_destroy(_self);

    _initialized = false;
  }
}

// ================= StreamPlayer, Engine, Sound, Generator =================
final class FfiStreamPlayer implements PlatformStreamPlayer {
  FfiStreamPlayer._(Pointer<bindings.StreamPlayer> self, this._channels)
      : _self = self;

  final Pointer<bindings.StreamPlayer> _self;
  final int _channels;

  Pointer<Float> _scratch = nullptr;
  int _scratchFloats = 0;

  Pointer<Int16> _scratchS16 = nullptr;
  int _scratchS16Samples = 0;

  double _volume = 1.0;
  @override
  double get volume => _volume;

  @override
  set volume(double v) {
    final clamped = v.isNaN ? 0.0 : v.clamp(0.0, 100.0).toDouble();
    _volume = clamped;
    bindings.stream_player_set_volume(_self, clamped);
  }

  double _pan = 0.0;
  @override
  double get pan => _pan;

  @override
  set pan(double v) {
    final clamped = v.isNaN ? 0.0 : v.clamp(-1.0, 1.0).toDouble();
    _pan = clamped;
    bindings.stream_player_set_pan(_self, clamped);
  }

  @override
  void start() {
    final ok = bindings.stream_player_start(_self);
    if (ok != 1) {
      throw MiniaudioDartPlatformException("stream_player_start failed.");
    }
  }

  @override
  void stop() {
    final ok = bindings.stream_player_stop(_self);
    if (ok != 1) {
      throw MiniaudioDartPlatformException("stream_player_stop failed.");
    }
  }

  @override
  void clear() {
    bindings.stream_player_clear(_self);
  }

  // Safely writes interleaved Float32 samples. Returns frames written by native side.
  @override
  int writeFloat32(Float32List interleaved) {
    if (interleaved.isEmpty) return 0;
    final int floats = interleaved.length;
    if (floats % _channels != 0) {
      throw MiniaudioDartPlatformException(
        "writeFloat32: floats ($floats) not divisible by channels ($_channels)",
      );
    }
    final int frames = floats ~/ _channels;

    if (_scratch == nullptr || _scratchFloats < floats) {
      if (_scratch != nullptr) calloc.free(_scratch);
      _scratch = calloc<Float>(floats);
      _scratchFloats = floats;
    }
    _scratch.asTypedList(floats).setAll(0, interleaved);

    final int written = bindings.stream_player_write_frames_f32(
      _self,
      _scratch,
      frames,
    );
    return written;
  }

  @override
  int writeInt16(Int16List interleaved) {
    if (interleaved.isEmpty) return 0;

    final int samples = interleaved.length;

    if (samples % _channels != 0) {
      throw MiniaudioDartPlatformException(
        "writeInt16: samples ($samples) not divisible by channels ($_channels)",
      );
    }

    final int frames = samples ~/ _channels;

    if (_scratchS16 == nullptr || _scratchS16Samples < samples) {
      if (_scratchS16 != nullptr) {
        calloc.free(_scratchS16);
      }

      _scratchS16 = calloc<Int16>(samples);
      _scratchS16Samples = samples;
    }

    _scratchS16.asTypedList(samples).setAll(0, interleaved);

    return bindings.stream_player_write_frames_s16(
      _self,
      _scratchS16,
      frames,
    );
  }

  @override
  bool pushData(dynamic data) {
    if (data is Float32List) {
      return writeFloat32(data) > 0;
    } else if (data is Int16List) {
      return writeInt16(data) > 0;
    }
    return false;
  }

  @override
  void dispose() {
    if (_scratch != nullptr) {
      calloc.free(_scratch);
      _scratch = nullptr;
      _scratchFloats = 0;
    }
    if (_scratchS16 != nullptr) {
      calloc.free(_scratchS16);
      _scratchS16 = nullptr;
      _scratchS16Samples = 0;
    }
    bindings.stream_player_free(_self);
  }
}

// engine ffi
final class FfiEngine implements PlatformEngine {
  FfiEngine(this._self);
  final Pointer<bindings.Engine> _self;
  bool _disposed = false;

  EngineState state = EngineState.uninit;

  @override
  Future<void> init(int periodMs) async {
    if (bindings.engine_init(_self, periodMs) != 1) {
      throw MiniaudioDartPlatformException("Failed to init the engine.");
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    bindings.engine_uninit(_self);
    bindings.engine_free(_self); // correct native free
    _disposed = true;
  }

  @override
  void start() {
    if (bindings.engine_start(_self) != 1) {
      throw MiniaudioDartPlatformException("Failed to start the engine.");
    }
  }

  @override
  Future<PlatformSound> loadSound(AudioData audioData) async {
    // Allocate exact number of float samples (elements), not bytes.
    final int sampleCount = audioData.buffer.length;
    final Pointer<Float> dataPtr = calloc<Float>(sampleCount);
    // Copy PCM into native buffer.
    dataPtr.asTypedList(sampleCount).setAll(0, audioData.buffer);
    // Size in bytes for the native API (if it expects bytes).
    final int dataSize = sampleCount * sizeOf<Float>();
    final Pointer<bindings.Sound> sound = bindings.sound_alloc();
    if (sound == nullptr) {
      calloc.free(dataPtr);
      throw MiniaudioDartPlatformException("Failed to allocate a sound.");
    }

    final int maFormat = audioData.format;
    final int result = bindings.engine_load_sound(
      _self,
      sound,
      dataPtr,
      dataSize,
      bindings.ma_format.fromValue(maFormat),
      audioData.sampleRate,
      audioData.channels,
    );

    if (result != 1) {
      bindings.sound_unload(sound);
      calloc.free(dataPtr); // avoid leak on failure
      throw MiniaudioDartPlatformException("Failed to load a sound.");
    }

    return FfiSound._fromPtrs(sound, dataPtr);
  }

  Future<List<(String name, bool isDefault)>> enumeratePlaybackDevices() async {
    // Refresh native cache
    bindings.engine_refresh_playback_devices(_self);
    final count = bindings.engine_get_playback_device_count(_self);
    final results = <(String, bool)>[];
    if (count == 0) return results;
    // Temporary buffer for names
    const cap = 256;
    final nameBuf = calloc<Int8>(cap);
    final isDefaultPtr = calloc<Uint8>();
    try {
      for (var i = 0; i < count; i++) {
        final ok = bindings.engine_get_playback_device_name(
          _self,
          i,
          nameBuf.cast(),
          cap,
          isDefaultPtr.cast(),
        );
        if (ok == 0) continue;
        final name = nameBuf.cast<Utf8>().toDartString();
        final isDef = isDefaultPtr.value != 0;
        results.add((name, isDef));
      }
    } finally {
      calloc.free(nameBuf);
      calloc.free(isDefaultPtr);
    }
    return results;
  }

  Future<bool> selectPlaybackDeviceByIndex(int index) async {
    // IMPORTANT: Existing Sound / StreamPlayer objects tied to previous engine
    // must be recreated after a successful switch.
    final ok = bindings.engine_select_playback_device_by_index(_self, index);
    return ok != 0;
  }

  @override
  int getPlaybackDeviceGeneration() =>
      bindings.engine_get_playback_device_generation(_self);

  Pointer<bindings.ma_engine> get _maEngine =>
      bindings.engine_get_ma_engine(_self);
}

// sound ffi
final class FfiSound implements PlatformSound {
  FfiSound._fromPtrs(Pointer<bindings.Sound> self, Pointer data)
      : _self = self,
        _data = data,
        _volume = bindings.sound_get_volume(self),
        _duration = bindings.sound_get_duration(self);

  final Pointer<bindings.Sound> _self;
  final Pointer _data;

  double _volume;
  @override
  double get volume => _volume;
  @override
  set volume(double value) {
    bindings.sound_set_volume(_self, value);
    _volume = value;
  }

  final double _duration;
  @override
  double get duration => _duration;

  PlatformSoundLooping _looping = (false, 0);
  @override
  PlatformSoundLooping get looping => _looping;
  @override
  set looping(PlatformSoundLooping value) {
    bindings.sound_set_looped(_self, value.$1, value.$2);
    _looping = value;
  }

  @override
  void unload() {
    bindings.sound_unload(_self);
    if (_data != nullptr) {
      calloc.free(_data); // only the temporary PCM copy
    }
    bindings.sound_free(_self); // NEW
  }

  @override
  void play() {
    if (bindings.sound_play(_self) != 1) {
      throw MiniaudioDartPlatformException("Failed to play the sound.");
    }
  }

  @override
  void replay() {
    bindings.sound_replay(_self);
  }

  @override
  void pause() => bindings.sound_pause(_self);
  @override
  void stop() => bindings.sound_stop(_self);

  @override
  bool rebindToEngine(PlatformEngine engine) {
    if (engine is! FfiEngine) return false;
    final nativeMaEngine = engine._maEngine; // Pointer<ma_engine>
    final res = bindings.sound_rebind_engine(_self, nativeMaEngine);
    return res == 1;
  }
}

// generator ffi
class FfiGenerator implements PlatformGenerator {
  FfiGenerator(Pointer<bindings.Generator> self)
      : _self = self,
        _volume = bindings.generator_get_volume(self);

  final Pointer<bindings.Generator> _self;

  double _volume;
  @override
  double get volume => _volume;
  @override
  set volume(double value) {
    bindings.generator_set_volume(_self, value);
    _volume = value;
  }

  double _pan = 0.0;
  @override
  double get pan => _pan;
  @override
  set pan(double value) {
    final clamped = value.clamp(-1.0, 1.0);
    bindings.generator_set_pan(_self, clamped);
    _pan = clamped;
  }

  @override
  Future<void> init(
    int format,
    int channels,
    int sampleRate,
    int bufferDurationSeconds,
  ) async {
    final result = bindings.generator_init(
      _self,
      bindings.ma_format.fromValue(format),
      channels,
      sampleRate,
      bufferDurationSeconds,
    );
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException(
        "Failed to initialize generator. Error code: $result",
      );
    }
  }

  @override
  void setWaveform(WaveformType type, double frequency, double amplitude) {
    final result = bindings.generator_set_waveform(
      _self,
      bindings.ma_waveform_type.fromValue(type.index),
      frequency,
      amplitude,
    );
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException("Failed to set waveform.");
    }
  }

  @override
  void setPulsewave(double frequency, double amplitude, double dutyCycle) {
    final result = bindings.generator_set_pulsewave(
      _self,
      frequency,
      amplitude,
      dutyCycle,
    );
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException("Failed to set pulse wave.");
    }
  }

  @override
  void setNoise(NoiseType type, int seed, double amplitude) {
    final result = bindings.generator_set_noise(
      _self,
      bindings.ma_noise_type.fromValue(type.index),
      seed,
      amplitude,
    );
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException("Failed to set noise.");
    }
  }

  @override
  void start() {
    final result = bindings.generator_start(_self);
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException("Failed to start generator.");
    }
  }

  @override
  void stop() {
    final result = bindings.generator_stop(_self);
    if (result != bindings.GeneratorResult.GENERATOR_OK) {
      throw MiniaudioDartPlatformException("Failed to stop generator.");
    }
  }

  Pointer<Float> bufferPtr = calloc.allocate<Float>(0);

  @override
  Float32List getBuffer(int framesToRead) {
    // Same as recorder: counts are elements, not bytes.
    final int requested = framesToRead;
    final Pointer<Float> ptr = calloc<Float>(requested);
    final int read = bindings.generator_get_buffer(_self, ptr, requested);
    if (read < 0) {
      calloc.free(ptr);
      throw MiniaudioDartPlatformException(
        "Failed to get generator buffer. Error code: $read",
      );
    }
    final out = Float32List.fromList(ptr.asTypedList(read));
    calloc.free(ptr);
    return out;
  }

  @override
  int getAvailableFrames() => bindings.generator_get_available_frames(_self);

  @override
  void dispose() {
    bindings.generator_destroy(_self);
  }
}
