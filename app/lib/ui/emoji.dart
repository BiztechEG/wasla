// Emoji: the picker under the message field, the quick reactions, and
// messages that are only an emoji or three.

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'widgets.dart';

/// The reactions offered first, before "+" for any other.
const quickReactions = ['👍', '❤️', '😂', '🎉', '✅', '🙏'];

bool _emojiRune(int r) =>
    r >= 0x1F000 ||
    (r >= 0x2190 && r <= 0x2BFF) ||
    (r >= 0x3030 && r <= 0x303D) ||
    r == 0x00A9 ||
    r == 0x00AE ||
    r == 0x200D ||
    r == 0x20E3 ||
    r == 0xFE0F ||
    (r >= 0xE0020 && r <= 0xE007F);

/// A message of one to three emoji and nothing else, shown big and without
/// a bubble.
bool isBigEmoji(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty) return false;
  final count = t.characters.length;
  if (count > 3) return false;
  // Digits, # and * are emoji only as keycaps (with U+20E3).
  for (final c in t.characters) {
    final runes = c.runes.toList();
    if (!runes.every(_emojiRune) &&
        !(runes.contains(0x20E3) &&
            runes.every((r) => _emojiRune(r) || r < 0x80))) {
      return false;
    }
    if (runes.every((r) => r == 0x200D || r == 0xFE0F)) return false;
  }
  return true;
}

/// Arabic words to search the most used emoji by, next to their English
/// names.
const _arabic = <String, String>{
  '😀': 'ابتسامة ضحك سعيد',
  '😃': 'ابتسامة ضحك سعيد',
  '😄': 'ابتسامة ضحك سعيد',
  '😁': 'ابتسامة ضحك',
  '😆': 'ضحك',
  '😅': 'ضحك عرق إحراج',
  '😂': 'ضحك دموع',
  '🤣': 'ضحك',
  '😊': 'ابتسامة خجل سعيد',
  '🙂': 'ابتسامة',
  '😉': 'غمزة',
  '😍': 'حب قلوب إعجاب',
  '🥰': 'حب قلوب',
  '😘': 'بوسة حب',
  '😎': 'نظارة رايق',
  '🤔': 'تفكير',
  '😐': 'محايد',
  '😴': 'نوم نعسان',
  '😮': 'مفاجأة دهشة',
  '😢': 'حزن بكاء زعل',
  '😭': 'بكاء حزن',
  '😡': 'غضب زعل',
  '😠': 'غضب',
  '🥳': 'احتفال عيد ميلاد',
  '😇': 'ملاك',
  '🙄': 'ملل',
  '😬': 'إحراج',
  '😱': 'خوف صدمة',
  '🤗': 'حضن',
  '🤝': 'مصافحة اتفاق',
  '👍': 'تمام موافق لايك إعجاب',
  '👎': 'لا رفض',
  '👏': 'تصفيق برافو',
  '🙏': 'شكرا دعاء رجاء',
  '👋': 'سلام أهلا تحية',
  '💪': 'قوة عضلات',
  '👌': 'تمام ممتاز',
  '✌️': 'سلام نصر',
  '🙌': 'احتفال يا سلام',
  '👀': 'عيون شايف بتابع',
  '❤️': 'قلب حب أحمر',
  '💔': 'قلب مكسور',
  '🔥': 'نار جامد',
  '⭐': 'نجمة',
  '✨': 'لمعان',
  '🎉': 'احتفال مبروك تهنئة',
  '🎊': 'احتفال',
  '🎁': 'هدية',
  '🎂': 'تورتة عيد ميلاد',
  '✅': 'صح تم موافق خلص',
  '❌': 'غلط إلغاء لا',
  '⚠️': 'تحذير انتباه',
  '❓': 'سؤال',
  '❗': 'تعجب مهم',
  '💯': 'مية ممتاز',
  '📌': 'دبوس تثبيت',
  '📎': 'مشبك ملف مرفق',
  '📁': 'ملف مجلد',
  '📄': 'ورقة مستند',
  '📊': 'رسم بياني تقرير',
  '📅': 'تقويم تاريخ موعد',
  '⏰': 'منبه وقت تذكير',
  '⌛': 'وقت انتظار',
  '📞': 'تليفون مكالمة',
  '📱': 'موبايل',
  '💻': 'كمبيوتر لابتوب',
  '📧': 'إيميل بريد',
  '💼': 'شغل حقيبة عمل',
  '💰': 'فلوس',
  '💡': 'فكرة لمبة',
  '🚀': 'صاروخ انطلاق',
  '🏆': 'كأس فوز',
  '☕': 'قهوة شاي',
  '🌙': 'هلال قمر رمضان',
  '☀️': 'شمس',
  '🌹': 'وردة',
  '🕌': 'مسجد',
  '🇪🇬': 'مصر علم',
  '🇸🇦': 'السعودية علم',
  '🇦🇪': 'الإمارات علم',
};

List<CategoryEmoji> _emojiSet(Locale locale) => [
  for (final c in emojiSetEnglish)
    c.copyWith(
      emoji: [
        for (final e in c.emoji)
          if (_arabic[e.emoji] case final ar?)
            Emoji(e.emoji, '${e.name} | $ar', hasSkinTone: e.hasSkinTone)
          else
            e,
      ],
    ),
];

/// The emoji picker, in the app's colors: recent ones, categories and
/// search. With [controller], picking types into that field.
class EmojiPanel extends StatelessWidget {
  const EmojiPanel({
    super.key,
    this.controller,
    this.onPicked,
    this.height = 280,
  });

  final TextEditingController? controller;
  final void Function(String emoji)? onPicked;
  final double height;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = theme.scaffoldBackgroundColor;
    return EmojiPicker(
      key: const Key('emojiPanel'),
      textEditingController: controller,
      onEmojiSelected: (_, e) => onPicked?.call(e.emoji),
      onBackspacePressed: controller == null ? null : () {},
      config: Config(
        height: height,
        emojiSet: _emojiSet,
        checkPlatformCompatibility: true,
        emojiViewConfig: EmojiViewConfig(
          columns: 8,
          emojiSizeMax:
              26 * (defaultTargetPlatform == TargetPlatform.iOS ? 1.2 : 1.0),
          backgroundColor: bg,
          noRecents: Text(
            l.noRecentEmoji,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        categoryViewConfig: CategoryViewConfig(
          backgroundColor: bg,
          indicatorColor: scheme.primary,
          iconColor: scheme.onSurfaceVariant,
          iconColorSelected: scheme.primary,
          backspaceColor: scheme.primary,
          dividerColor: scheme.outlineVariant,
        ),
        skinToneConfig: SkinToneConfig(
          dialogBackgroundColor: scheme.surface,
          indicatorColor: scheme.onSurfaceVariant,
        ),
        bottomActionBarConfig: BottomActionBarConfig(
          showBackspaceButton: false,
          backgroundColor: bg,
          buttonColor: bg,
          buttonIconColor: scheme.onSurfaceVariant,
        ),
        searchViewConfig: SearchViewConfig(
          backgroundColor: bg,
          buttonIconColor: scheme.onSurfaceVariant,
          hintText: l.searchEmoji,
        ),
      ),
    );
  }
}

/// Any emoji, from a sheet; null if none was picked.
Future<String?> pickEmoji(BuildContext context) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: EmojiPanel(
        height: 340,
        onPicked: (e) => Navigator.pop(context, e),
      ),
    ),
  ),
);

/// The quick reactions in a row, then "+" for any other emoji. [mine] are
/// the ones the signed-in user already chose, drawn selected.
class ReactionBar extends StatelessWidget {
  const ReactionBar({
    super.key,
    required this.mine,
    required this.onPick,
    required this.onMore,
  });

  final Set<String> mine;
  final void Function(String emoji) onPick;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in quickReactions)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              key: Key('react-$e'),
              customBorder: const CircleBorder(),
              onTap: () => onPick(e),
              child: Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: mine.contains(e)
                    ? BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primaryContainer,
                      )
                    : null,
                child: Text(e, style: const TextStyle(fontSize: 24)),
              ),
            ),
          ),
        Tooltip(
          message: l.moreEmoji,
          child: InkWell(
            key: const Key('reactMore'),
            customBorder: const CircleBorder(),
            onTap: onMore,
            child: Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHigh,
              ),
              child: Icon(Icons.add, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ],
    );
  }
}
