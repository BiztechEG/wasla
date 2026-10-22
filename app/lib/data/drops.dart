import 'dart:ui' show Offset;

import 'chat_models.dart';
import 'drops_none.dart' if (dart.library.js_interop) 'drops_web.dart';

/// Files dragged from the computer onto the app, in a browser. Tests swap
/// in a fake.
abstract class FileDrops {
  /// Where files are being dragged over the window; null once they leave
  /// or are dropped.
  Stream<Offset?> get hover;

  /// Files dropped on the window, and where.
  Stream<FileDrop> get dropped;
}

/// What a drop brought: up to one more file than a send takes (so too many
/// can be told apart), and how many were over the size limit.
typedef FileDrop = ({Offset at, List<Upload> files, int tooLarge});

/// This device's file drops: the browser's, or none.
FileDrops deviceFileDrops() => platformFileDrops();
