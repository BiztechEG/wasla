import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Hands text or a file to the phone's (or browser's) share sheet, to send
/// to other apps. Tests swap in a fake.
abstract class Sharer {
  /// False when there is no share sheet here (some browsers and desktops),
  /// so the caller can copy or download instead. With [download], a file is
  /// downloaded there instead.
  Future<bool> share({String? text, SharedFile? file, bool download = false});
}

/// A file's contents, to share as the file itself rather than a link.
class SharedFile {
  const SharedFile({
    required this.bytes,
    required this.name,
    required this.mime,
  });

  final Uint8List bytes;
  final String name;
  final String mime;
}

class DeviceSharer implements Sharer {
  @override
  Future<bool> share({
    String? text,
    SharedFile? file,
    bool download = false,
  }) async {
    final body = (text?.trim().isEmpty ?? true) ? null : text;
    if (body == null && file == null) return true;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: body,
          files: file == null
              ? null
              : [
                  XFile.fromData(
                    file.bytes,
                    mimeType: file.mime,
                    name: file.name,
                  ),
                ],
          fileNameOverrides: file == null ? null : [file.name],
          downloadFallbackEnabled: download,
          mailToFallbackEnabled: false,
        ),
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }
}
