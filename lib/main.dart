import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/canvas_screen.dart';

void main() {
  if (kIsWeb) {
    // Right-click is used to remove waypoints/bays; suppress the browser's
    // native context menu so it doesn't cover the canvas.
    BrowserContextMenu.disableContextMenu();
  }
  runApp(const ParkingLayoutApp());
}

class ParkingLayoutApp extends StatelessWidget {
  const ParkingLayoutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Parking Layout — Canvas Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3E5C76)),
        useMaterial3: true,
      ),
      home: const CanvasScreen(),
    );
  }
}
