import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_models.dart';

/// The largest file the server accepts.
const maxUploadBytes = 50 * 1024 * 1024;

/// The largest logo the server accepts.
const maxLogoBytes = 2 * 1024 * 1024;

class FileTooLarge implements Exception {
  const FileTooLarge();
}

/// A logo must be a PNG, JPEG or WebP image.
class UnsupportedLogo implements Exception {
  const UnsupportedLogo();
}

/// The file extension a logo of type [mime] is saved with, or null when the
/// server does not take that type.
String? logoExtension(String mime) => switch (mime.toLowerCase()) {
  'image/png' => 'png',
  'image/jpeg' || 'image/jpg' => 'jpg',
  'image/webp' => 'webp',
  _ => null,
};

/// Picks photos and files on the phone. Tests swap in a fake.
abstract class Picker {
  /// [maxSide] shrinks big photos so their longest side fits.
  Future<Upload?> pickImage({required bool camera, int maxSide = 2048});
  Future<Upload?> pickFile();
}

class DevicePicker implements Picker {
  @override
  Future<Upload?> pickImage({required bool camera, int maxSide = 2048}) async {
    // Shrunk on the phone so photos upload quickly over mobile data.
    final image = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: maxSide.toDouble(),
      maxHeight: maxSide.toDouble(),
      imageQuality: 80,
    );
    if (image == null) return null;
    final bytes = await image.readAsBytes();
    if (bytes.length > maxUploadBytes) throw const FileTooLarge();
    return Upload(
      bytes: bytes,
      name: image.name,
      mime: image.mimeType ?? mimeFor(image.name),
    );
  }

  @override
  Future<Upload?> pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    if ((await file.length() ?? 0) > maxUploadBytes) {
      throw const FileTooLarge();
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > maxUploadBytes) throw const FileTooLarge();
    return Upload(bytes: bytes, name: file.name, mime: mimeFor(file.name));
  }
}
