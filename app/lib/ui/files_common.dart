import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/picker.dart';
import '../state/chat_providers.dart';
import 'chat_format.dart';
import 'widgets.dart';

/// Asks where to pick from (gallery, camera or files) and returns the pick.
Future<Upload?> pickUpload(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l.attachPhoto),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.attachCamera),
            onTap: () => Navigator.pop(context, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(l.attachFile),
            onTap: () => Navigator.pop(context, 'file'),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;
  final picker = ref.read(pickerProvider);
  try {
    return switch (source) {
      'file' => await picker.pickFile(),
      _ => await picker.pickImage(camera: source == 'camera'),
    };
  } on FileTooLarge {
    if (context.mounted) showMessage(context, l.fileTooLarge);
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(l, e));
  }
  return null;
}

/// Photos open full screen; anything else opens in the phone's viewer.
Future<void> openFile(
  BuildContext context,
  WidgetRef ref,
  ChatFile file,
) async {
  if (file.isImage) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ImageViewerScreen(file: file)),
    );
    return;
  }
  try {
    final url = await ref.read(fileUrlProvider(file.path).future);
    if (context.mounted) await openLink(context, url);
  } catch (e) {
    if (context.mounted) showMessage(context, errorText(context.l10n, e));
  }
}

/// A stored photo, loaded through a short-lived link.
class StoredImage extends ConsumerWidget {
  const StoredImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.placeholderHeight = 180,
  });

  final String path;
  final BoxFit fit;
  final double placeholderHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    Widget box(IconData icon) => Container(
      height: placeholderHeight,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(icon, color: scheme.onSurfaceVariant),
    );
    // Offline or an expired link: tap to load it again.
    final failed = GestureDetector(
      onTap: () => ref.invalidate(fileUrlProvider(path)),
      child: box(Icons.refresh),
    );
    final link = ref.watch(fileUrlProvider(path));
    if (link.hasError) return failed;
    final url = link.value;
    if (url == null || url.isEmpty) return box(Icons.image_outlined);
    return Image.network(
      url,
      fit: fit,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : box(Icons.image_outlined),
      errorBuilder: (_, _, _) => failed,
    );
  }
}

class ImageViewerScreen extends ConsumerWidget {
  const ImageViewerScreen({super.key, required this.file});

  final ChatFile file;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Theme(
      data: ThemeData.dark(),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(file.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: l.openFile,
              icon: const Icon(Icons.open_in_new),
              onPressed: () async {
                final url = await ref.read(fileUrlProvider(file.path).future);
                if (context.mounted) await openLink(context, url);
              },
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 5,
            child: StoredImage(path: file.path, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

/// A file as a row: type badge, name, and a line of detail.
class FileRow extends StatelessWidget {
  const FileRow({
    super.key,
    required this.file,
    required this.detail,
    this.dense = false,
  });

  final ChatFile file;
  final String detail;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        FileBadge(name: file.name, size: dense ? 36 : 40),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                file.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
