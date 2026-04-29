// lib/models/block_models.dart

class UserBlocksResponse {
  final List<String> blockedUids;
  final List<String> blockedByUids;

  UserBlocksResponse({
    required this.blockedUids,
    required this.blockedByUids,
  });

  factory UserBlocksResponse.fromJson(Map<String, dynamic> json) {
    return UserBlocksResponse(
      blockedUids:
          (json['blocked_uids'] as List<dynamic>? ?? []).cast<String>(),
      blockedByUids:
          (json['blocked_by_uids'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
}
