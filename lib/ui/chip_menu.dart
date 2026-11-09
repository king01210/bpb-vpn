import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'theme.dart';

/// Chip showing the selected value; tapping opens a menu with the selected item highlighted.
class ChipMenu<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) label;

  /// Optional tags after the label (e.g. the protocol), each in its own badge.
  final List<String> Function(T)? badges;

  /// Optional tags under the label, in the open menu only (e.g. a chain proxy's protocol).
  final List<String> Function(T)? subtitleBadges;
  final ValueChanged<T> onSelected;
  final bool enabled;

  const ChipMenu({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    this.badges,
    this.subtitleBadges,
    required this.onSelected,
    this.enabled = true,
  });

  /// One tag (a protocol, TCP / UDP…), as the chips show it; also used by ChoicePref.
  static Widget badge(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedBadges = badges?.call(selected) ?? const <String>[];
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(shape: WidgetStatePropertyAll(roundedShape(kMenuRadius))),
      menuChildren: [
        for (final v in values)
          MenuItemButton(
            // The selected item gets a tinted background and bold text.
            style: v == selected
                ? MenuItemButton.styleFrom(
                    backgroundColor: scheme.secondaryContainer,
                    foregroundColor: scheme.onSecondaryContainer,
                    textStyle: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  )
                : null,
            onPressed: () => onSelected(v),
            // Same width on every row; the name takes the free space, so tags line up on the right.
            child: SizedBox(
              width: 170,
              child: Row(
                children: [
                  Expanded(
                    child: switch (subtitleBadges?.call(v)) {
                      final tags? when tags.isNotEmpty => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label(v), overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Wrap(spacing: 4, runSpacing: 4, children: [for (final tag in tags) badge(context, tag)]),
                          ],
                        ),
                      ),
                      _ => Text(label(v), overflow: TextOverflow.ellipsis),
                    },
                  ),
                  if (badges?.call(v) case final tags?)
                    for (final (i, tag) in tags.indexed) ...[SizedBox(width: i == 0 ? 12 : 4), badge(context, tag)],
                ],
              ),
            ),
          ),
      ],
      builder: (context, controller, _) => Material(
        color: scheme.surfaceContainerHighest,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: enabled ? () => controller.isOpen ? controller.close() : controller.open() : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label(selected), style: theme.textTheme.labelLarge),
                for (final (i, tag) in selectedBadges.indexed) ...[
                  SizedBox(width: i == 0 ? 6 : 4),
                  badge(context, tag),
                ],
                AnimatedRotation(
                  turns: controller.isOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Symbols.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
