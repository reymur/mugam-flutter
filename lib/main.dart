import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/colors.dart';
import 'core/theme/typography.dart';
import 'firebase_options.dart';
import 'navigation/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(child: MugamApp()));
}

class MugamApp extends StatelessWidget {
  const MugamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Mugam',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: kGold,
          secondary: kGold,
          surface: kBg2,
          onPrimary: kBg,
          onSurface: kText,
        ),
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg2,
          foregroundColor: kText,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        textTheme: buildTextTheme(),
        dividerColor: kBorder,
        cardColor: kCard,
      ),
    );
  }
}
