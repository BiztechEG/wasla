import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/chat_models.dart';
import '../l10n/app_localizations.dart';
import 'widgets.dart';

/// Western digits everywhere, matching the counts elsewhere in the app.
String westernDigits(String text) => text.replaceAllMapped(
  RegExp('[٠-٩]'),
  (m) => '${m[0]!.codeUnitAt(0) - 0x0660}',
);

String _locale(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 10:45 ص
String clockTime(BuildContext context, DateTime time) => westernDigits(
  DateFormat('h:mm a', _locale(context)).format(time.toLocal()),
);

/// For the chat list: the time today, "yesterday", a weekday, or a date.
String listTime(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  if (_sameDay(local, now)) return clockTime(context, local);
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return context.l10n.yesterday;
  }
  final locale = _locale(context);
  if (now.difference(local).inDays < 7) {
    return DateFormat('EEEE', locale).format(local);
  }
  return westernDigits(DateFormat('d/M/yyyy', locale).format(local));
}

/// For the line between days in a chat.
String dayLabel(BuildContext context, DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  if (_sameDay(local, now)) return context.l10n.today;
  if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    return context.l10n.yesterday;
  }
  final pattern = local.year == now.year ? 'EEEE d MMMM' : 'd MMMM yyyy';
  return westernDigits(DateFormat(pattern, _locale(context)).format(local));
}

String fileSize(AppLocalizations l, int bytes) {
  if (bytes >= 1024 * 1024) {
    final mb = bytes / (1024 * 1024);
    return l.sizeMb(mb >= 10 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1));
  }
  return l.sizeKb(((bytes / 1024).ceil()).toString());
}

/// What a chat-list row says about its last message.
String preview(AppLocalizations l, Conversation c, String? me) {
  if (c.lastAt == null) return l.noMessagesYet;
  final String text;
  if (c.lastDeleted) {
    text = l.previewDeleted;
  } else if (c.lastBody != null && c.lastBody!.isNotEmpty) {
    text = c.lastBody!;
  } else {
    text = c.lastFileName ?? '';
  }
  if (c.lastSenderId == me) return l.previewFrom(l.you, text);
  if (c.isProject) {
    return l.previewFrom(firstName(c.lastSenderName ?? ''), text);
  }
  return text;
}

String firstName(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.isEmpty ? name : parts.first;
}

/// A colored square with the file's type, as in the design.
class FileBadge extends StatelessWidget {
  const FileBadge({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final (label, color) = switch (ext) {
      'pdf' => ('PDF', const Color(0xFFB4441C)),
      'xls' || 'xlsx' || 'csv' => ('XLS', const Color(0xFF1D6B42)),
      'doc' || 'docx' => ('DOC', const Color(0xFF2F5BD3)),
      'ppt' || 'pptx' => ('PPT', const Color(0xFFC2660A)),
      'jpg' ||
      'jpeg' ||
      'png' ||
      'gif' ||
      'webp' ||
      'heic' => ('IMG', const Color(0xFF0F6E6A)),
      'zip' || 'rar' => ('ZIP', const Color(0xFF5B6876)),
      'dwg' || 'dxf' => ('DWG', const Color(0xFF7247B8)),
      _ => (
        ext.isEmpty || ext.length > 4 ? 'FILE' : ext.toUpperCase(),
        const Color(0xFF5B6876),
      ),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.27,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Opens a stored file in the phone's viewer or browser.
Future<void> openLink(BuildContext context, String url) async {
  final l = context.l10n;
  final messenger = ScaffoldMessenger.of(context);
  final ok =
      url.isNotEmpty &&
      await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ).catchError((Object _) => false);
  if (!ok) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.cantOpenFile)));
  }
}
