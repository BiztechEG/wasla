import 'dart:io' show File;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'chat_models.dart';

/// The longest voice message; recording stops and sends at this point.
const maxVoiceLength = Duration(minutes: 10);

/// Voice messages are named `voice_<seconds>s.<ext>`, so a chat can show
/// their length before playing them.
String voiceName(Duration length, String ext) =>
    'voice_${length.inSeconds}s.$ext';

final _voiceName = RegExp(r'^voice_(\d+)s\.\w+$');

/// The length of a voice message, or null when [file] is not one.
Duration? voiceLength(String name) {
  final match = _voiceName.firstMatch(name);
  return match == null ? null : Duration(seconds: int.parse(match[1]!));
}

/// Records voice messages from the microphone. Tests swap in a fake.
abstract class VoiceRecorder {
  /// False when the microphone may not be used.
  Future<bool> start();

  /// Ends the recording and returns it, ready to send.
  Future<Upload?> stop(Duration length);

  Future<void> cancel();
}

class DeviceVoiceRecorder implements VoiceRecorder {
  AudioRecorder? _recorder;
  String _ext = 'm4a';
  String _mime = 'audio/mp4';

  @override
  Future<bool> start() async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) return false;
    var encoder = AudioEncoder.aacLc;
    _ext = 'm4a';
    _mime = 'audio/mp4';
    // Browsers other than Safari don't record AAC.
    if (kIsWeb && !await recorder.isEncoderSupported(encoder)) {
      if (await recorder.isEncoderSupported(AudioEncoder.opus)) {
        encoder = AudioEncoder.opus;
        _ext = 'webm';
        _mime = 'audio/webm';
      } else {
        encoder = AudioEncoder.wav;
        _ext = 'wav';
        _mime = 'audio/wav';
      }
    }
    final path = kIsWeb
        ? ''
        : '${(await getTemporaryDirectory()).path}/'
              'voice-${DateTime.now().millisecondsSinceEpoch}.$_ext';
    await recorder.start(
      RecordConfig(encoder: encoder, bitRate: 64000, numChannels: 1),
      path: path,
    );
    return true;
  }

  @override
  Future<Upload?> stop(Duration length) async {
    final path = await _recorder?.stop();
    if (path == null) return null;
    final bytes = await XFile(path).readAsBytes();
    if (!kIsWeb) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    if (bytes.isEmpty) return null;
    return Upload(bytes: bytes, name: voiceName(length, _ext), mime: _mime);
  }

  @override
  Future<void> cancel() async => _recorder?.cancel();
}
