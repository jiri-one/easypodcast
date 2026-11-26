import 'package:flutter/widgets.dart';

import '../app_root.dart';
import 'demo_services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await createDemoServices();
  runApp(EasyPodcastApp(services: services));
}
