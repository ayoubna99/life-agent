import 'package:flutter/material.dart';

import 'app_services.dart';
import 'config.dart';
import 'onboarding/onboarding_page.dart';
import 'ui/home_page.dart';
import 'ui/intro.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(LifeApp(services: AppServices.real()));
}

class LifeApp extends StatelessWidget {
  const LifeApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Life',
      debugShowCheckedModeBanner: false,
      theme: lifeTheme(Brightness.light),
      darkTheme: lifeTheme(Brightness.dark),
      home: AppConfig.supabaseKey.isEmpty
          ? const _MissingKey()
          : IntroGate(
              child: OnboardingGate(
                services: services,
                child: HomePage(services: services),
              ),
            ),
    );
  }
}

/// A build without the publishable key cannot reach the agent: say so instead of failing on every tap.
class _MissingKey extends StatelessWidget {
  const _MissingKey();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'This build has no server key.\nBuild with --dart-define=SUPA_KEY=<publishable key>.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}
