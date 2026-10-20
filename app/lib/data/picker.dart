import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_models.dart';

/// The largest file the server accepts.
const maxUploadBytes = 50 * 1024 * 1024;

/// The largest logo the server accepts.
const maxLogoBytes = 2 * 1024 * 1024;

/// The most files one send (or one upload) takes.
const maxFilesPerPick = 5;

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
  /// [maxSide] shrinks big photos so their longest side fits; [front] opens
  /// the selfie camera.
  Future<Upload?> pickImage({
    required bool camera,
    int maxSide = 2048,
    bool front = false,
  });
  Future<Upload?> pickVideo({required bool camera});
  Future<Upload?> pickFile();

  /// Several gallery photos, or several files. Files over [maxUploadBytes]
  /// are left out and counted in `tooLarge`.
  Future<Picked> pickImages({int limit = maxFilesPerPick});
  Future<Picked> pickFiles();
}

/// What a multiple pick brought back.
typedef Picked = ({List<Upload> files, int tooLarge});

class DevicePicker implements Picker {
  @override
  Future<Upload?> pickImage({
    required bool camera,
    int maxSide = 2048,
    bool front = false,
  }) async {
    // Shrunk on the phone so photos upload quickly over mobile data.
    final image = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      preferredCameraDevice: front ? CameraDevice.front : CameraDevice.rear,
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
  Future<Upload?> pickVideo({required bool camera}) async {
    final video = await ImagePicker().pickVideo(
      source: camera ? ImageSource.camera : ImageSource.gallery,
    );
    if (video == null) return null;
    if (await video.length() > maxUploadBytes) throw const FileTooLarge();
    final bytes = await video.readAsBytes();
    final mime = video.mimeType ?? mimeFor(video.name);
    return Upload(
      bytes: bytes,
      name: video.name,
      // Some phones name a recording without a known extension.
      mime: mime.startsWith('video/') ? mime : 'video/mp4',
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

  @override
  Future<Picked> pickImages({int limit = maxFilesPerPick}) async {
    final images = await ImagePicker().pickMultiImage(
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 80,
      limit: limit,
    );
    final files = <Upload>[];
    var tooLarge = 0;
    for (final image in images) {
      final bytes = await image.readAsBytes();
      if (bytes.length > maxUploadBytes) {
        tooLarge++;
        continue;
      }
      files.add(
        Upload(
          bytes: bytes,
          name: image.name,
          mime: image.mimeType ?? mimeFor(image.name),
        ),
      );
    }
    return (files: files, tooLarge: tooLarge);
  }

  @override
  Future<Picked> pickFiles() async {
    final picked = await FilePicker.pickFiles();
    final files = <Upload>[];
    var tooLarge = 0;
    for (final file in picked) {
      if ((await file.length() ?? 0) > maxUploadBytes) {
        tooLarge++;
        continue;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > maxUploadBytes) {
        tooLarge++;
        continue;
      }
      files.add(
        Upload(bytes: bytes, name: file.name, mime: mimeFor(file.name)),
      );
    }
    return (files: files, tooLarge: tooLarge);
  }
}
