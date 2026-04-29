import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiConfig {
  static String get baseUrl => (dotenv.env['BASE_URL'] ?? '').trim().isNotEmpty
      ? dotenv.env['BASE_URL']!.trim()
      : 'https://attachmates-backend.onrender.com'; //'http://192.168.100.2:8000'; //'http://192.168.254.111:8000'; //'http://192.168.83.234:8000'; // fallback for dev

  static String get wsUrl => (dotenv.env['WS_URL'] ?? '').trim().isNotEmpty
      ? dotenv.env['WS_URL']!.trim()
      : 'ws://attachmates-backend.onrender.com/ws'; //'ws://192.168.254.111:8000/ws'; //'ws://192.168.100.2:8000/ws'; //'ws://192.168.83.234:8000/ws'; //
}
