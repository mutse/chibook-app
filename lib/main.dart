import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/erdu_app.dart';
import 'services/tts_audio_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeAudioService();
  runApp(const ProviderScope(child: ErduApp()));
}
