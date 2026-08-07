import 'package:flutter/material.dart';

const Color kBg = Color(0xFF0C0A06);
const Color kBg2 = Color(0xFF131009);
const Color kBg3 = Color(0xFF1C1710);
const Color kCard = Color(0xFF18140D);
const Color kBorder = Color(0x26D4A03C);
const Color kGold = Color(0xFFD4A03C);
const Color kGold2 = Color(0xFFF0C060);
const Color kGoldDim = Color(0x14D4A03C);
const Color kRed = Color(0xFFC0392B);
const Color kGreen = Color(0xFF27AE60);
const Color kText = Color(0xFFF5EAD8);
const Color kMuted = Color(0xFF8A7A60);

// ТРИ ВРЕМЕННЫХ ЗАМЕСТИТЕЛЯ, заведены 07.08 для дневного экрана.
//
// Макет (`docs/design/mugam-1-esas.html`) строит текст на ЧЕТЫРЁХ
// уровнях, а в палитре их два — `kText` и `kMuted`. Не хватало не
// одного уровня, а двух: вторичного и приглушённого.
//
// Взяты ТЁПЛЫМИ эквивалентами макетных `#A8A8A2`, `#8A8A85`, `#3A3A38`,
// а не самими макетными: нейтральный серый рядом с коричневым `kMuted`
// даёт не иерархию, а грязь — разная температура при одинаковой
// светлоте.
//
// **В работе 7б они ЗАМЕНЯЮТСЯ на макетные, а не встают рядом с ними.**
// Иначе здесь окажется шесть уровней вместо четырёх, и через месяц никто
// не вспомнит, почему их шесть.
const Color kTextSecondary = Color(0xFFBFB093);
const Color kTextDim = Color(0xFF5F564A);
const Color kBarOff = Color(0xFF3A322A);
// Darker and clearly distinct from kMuted — used for the voice message
// "not read yet" cursor/wave state, which needs to stay visible against
// the light gold outgoing-bubble background (kMuted is too close to gold
// in brightness there) while remaining unmistakably different from
// kMuted's own "read but not listened to" wave state.
const Color kUnreadGray = Color(0xFF4A4A4A);
const Color kReadBlue = Color(0xFF1A6B9E);
// Brighter/more saturated than kReadBlue — kReadBlue's luminance is too
// close to kMuted's (the "read but not listened" wave color) to read as
// a clearly different state at a glance on a thin waveform bar. This is
// WhatsApp's own read-tick blue, picked specifically for its strong
// luminance/saturation gap from kMuted. Used only for the voice message
// "listened" wave color, not the dot or checkmarks (which keep kReadBlue).
const Color kListenedBlue = Color(0xFF2D9DCF);

const double kRadius = 18.0;
const double kNavH = 68.0;
