import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'chat_models.dart';

/// The largest file the server accepts.
const maxUploadBytes = 50 * 1024 * 1024;

class FileTooLarge implements Exception {
  const FileTooLarge();
}

/// Picks photos and files on the phone. Tests swap in a fake.
abstract class Picker {
  Future<Upload?> pickImage({required bool camera});
  Future<Upload?> pickFile();
}

class DevicePicker implements Picker {
  @override
  Future<Upload?> pickImage({required bool camera}) async {
    // Shrunk on the phone so photos upload quickly over mobile data.
    final image = await ImagePicker().pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
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
