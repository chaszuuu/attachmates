// lib/utils/eligibility_cache.dart
import 'dart:async';
import '../utils/api_client.dart';

class ReassessEligibility {
  final bool eligible;
  final int retryInDays;
  final DateTime fetchedAt;
  ReassessEligibility({
    required this.eligible,
    required this.retryInDays,
    required this.fetchedAt,
  });
}

class ReassessEligibilityCache {
  ReassessEligibilityCache._();
  static final instance = ReassessEligibilityCache._();

  ReassessEligibility? _last;
  Future<ReassessEligibility>? _inFlight;

  Future<ReassessEligibility> get({bool forceRefresh = false}) {
    if (!forceRefresh && _last != null) {
      final age = DateTime.now().difference(_last!.fetchedAt);
      if (age.inSeconds < 60) return Future.value(_last);
    }
    _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<ReassessEligibility> _fetch() async {
    try {
      final res = await ApiClient.getReassessEligibility()
          .timeout(const Duration(seconds: 2));
      final data = ReassessEligibility(
        eligible: (res['eligible'] == true),
        retryInDays: (res['retry_in_days'] as num?)?.toInt() ?? 0,
        fetchedAt: DateTime.now(),
      );
      _last = data;
      return data;
    } on TimeoutException {
      if (_last != null) return _last!;
      rethrow;
    } catch (_) {
      if (_last != null) return _last!;
      rethrow;
    }
  }
}
