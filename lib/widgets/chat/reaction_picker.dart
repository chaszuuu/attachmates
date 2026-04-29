// lib/widgets/chat/reaction_picker.dart
import "package:flutter/material.dart";
import "../../utils/constants.dart";

class ReactionPicker extends StatelessWidget {
  final void Function(String emoji) onPick;
  final List<String> emojis;
  final double emojiSize;

  const ReactionPicker({
    super.key,
    required this.onPick,
    this.emojis = kSupportedReactions,     // 👈 default from constants.dart
    this.emojiSize = kReactionTrayEmojiSize,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              blurRadius: 12,
              spreadRadius: 1,
              offset: Offset(0, 4),
              color: Color(0x22000000),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: emojis.map((emoji) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: GestureDetector(
                onTap: () => onPick(emoji),
                child: Text(
                  emoji,
                  style: TextStyle(fontSize: emojiSize),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
