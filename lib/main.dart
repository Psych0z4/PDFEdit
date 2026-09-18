import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/di.dart';
import 'features/home/presentation/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicjalizuje PDFium i jego isolate workera. Musi pójść przed pierwszym
  // wywołaniem silnika, bo edytor korzysta z tego samego workera co viewer.
  await pdfrxFlutterInitialize();

  setupDependencies();
  runApp(const PdfEditorApp());
}

class PdfEditorApp extends StatelessWidget {
  const PdfEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edytor PDF',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D5AFE),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
