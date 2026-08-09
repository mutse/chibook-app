import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/theme.dart';
import 'app_router.dart';
import 'app_state.dart';

class ErduApp extends ConsumerWidget {
  const ErduApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(appControllerProvider.select((s) => s.settings));
    final theme = switch (setting.theme) {
      ReaderTheme.dark => buildAppTheme(brightness: Brightness.dark),
      ReaderTheme.eye => buildAppTheme(
        brightness: Brightness.light,
        canvas: AppColors.eye,
      ),
      ReaderTheme.light => buildAppTheme(brightness: Brightness.light),
    };
    return MaterialApp.router(
      title: 'chibook',
      debugShowCheckedModeBanner: false,
      theme: theme,
      routerConfig: appRouter,
    );
  }
}
