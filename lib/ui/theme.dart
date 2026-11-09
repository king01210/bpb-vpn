import 'package:flutter/material.dart';

import '../models/theme_color.dart';

// The app's look in one place: the design values below, and [buildTheme], which applies
// them to every Material component. Restyle here rather than in individual widgets.

// region shapes

// Corner radii follow the card's role: the big status card is the hero and gets the
// extra-large shape; the smaller cards around it share one radius so they read as a group.

/// Status card.
const kHeroRadius = 28.0;

/// Traffic, usage and banner cards.
const kCardRadius = 20.0;

/// Material's default card radius, for the other cards in the app.
const kSmallCardRadius = 12.0;

/// Dialogs (Material's default radius).
const kDialogRadius = 28.0;

/// Menus and dropdown lists.
const kMenuRadius = 16.0;

/// Text fields and dropdown fields, like the small cards they sit in.
const kInputRadius = 12.0;

/// Superellipse ("squircle") corners everywhere: they blend into the edges more smoothly
/// than circular ones.
RoundedSuperellipseBorder roundedShape(double radius, {BorderSide side = BorderSide.none}) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius), side: side);

// endregion

// region form spacing

/// Space between stacked fields in a form card (fragments, noises).
const kFieldGap = 16.0;

/// Space on each side of the "–" between a min and a max field.
const kRangeDashGap = 12.0;

// endregion

/// The app theme for [brightness], with the palette seeded from [color] (picked in Settings).
ThemeData buildTheme(Brightness brightness, ThemeColor color) {
  final scheme = ColorScheme.fromSeed(seedColor: color.seed, brightness: brightness);
  final theme = _buildTheme(scheme);
  // No letter spacing: Material's (up to 0.5) is tuned for Roboto. It's applied to the finished
  // theme's text styles, which already carry the colors and font; to turn it off, return
  // `theme` instead.
  // return theme.copyWith(textTheme: _withoutLetterSpacing(theme.textTheme));
  return theme;
}

ThemeData _buildTheme(ColorScheme scheme) {
  final inputDecoration = InputDecorationTheme(
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(kInputRadius)),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'OpenSans',
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20)),
    // Superellipse corners for every card and dialog.
    cardTheme: CardThemeData(shape: roundedShape(kSmallCardRadius)),
    dialogTheme: DialogThemeData(shape: roundedShape(kDialogRadius)),
    // One style for every text and dropdown field. For filled fields instead of outlined:
    // InputDecorationTheme(filled: true, border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: …)).
    inputDecorationTheme: inputDecoration,
    menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(roundedShape(kMenuRadius)))),
    // DropdownMenu doesn't fall back to the theme's inputDecorationTheme (it'd get Flutter's
    // 4 px corners), so its field gets the same one.
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: inputDecoration,
      menuStyle: MenuStyle(shape: WidgetStatePropertyAll(roundedShape(kMenuRadius))),
    ),
    // Floating messages, shaped like the small cards.
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: roundedShape(kSmallCardRadius)),
    // Material Symbols Rounded variable axes; tweak here to restyle every icon.
    iconTheme: IconThemeData(color: scheme.onSurfaceVariant, fill: 0, weight: 400, grade: 0, opticalSize: 24),
  );
}

// TextTheme _withoutLetterSpacing(TextTheme t) => TextTheme(
//   displayLarge: t.displayLarge?.copyWith(letterSpacing: 0),
//   displayMedium: t.displayMedium?.copyWith(letterSpacing: 0),
//   displaySmall: t.displaySmall?.copyWith(letterSpacing: 0),
//   headlineLarge: t.headlineLarge?.copyWith(letterSpacing: 0),
//   headlineMedium: t.headlineMedium?.copyWith(letterSpacing: 0),
//   headlineSmall: t.headlineSmall?.copyWith(letterSpacing: 0),
//   titleLarge: t.titleLarge?.copyWith(letterSpacing: 0),
//   titleMedium: t.titleMedium?.copyWith(letterSpacing: 0),
//   titleSmall: t.titleSmall?.copyWith(letterSpacing: 0),
//   bodyLarge: t.bodyLarge?.copyWith(letterSpacing: 0),
//   bodyMedium: t.bodyMedium?.copyWith(letterSpacing: 0),
//   bodySmall: t.bodySmall?.copyWith(letterSpacing: 0),
//   labelLarge: t.labelLarge?.copyWith(letterSpacing: 0),
//   labelMedium: t.labelMedium?.copyWith(letterSpacing: 0),
//   labelSmall: t.labelSmall?.copyWith(letterSpacing: 0),
// );
