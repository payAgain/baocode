import 'package:bao_link/bao_link.dart';

/// Initial consent protocol. Reconnects use ordinary hello with the saved key.
/// All fields here are public. Neither an invite token nor a seed travels on
/// the reverse leg, and the correlation ID is never a credential.
abstract final class DesktopMutualPairing {
  static const version = 1;
  static const capability = 'mutualWorkspace';
  static const prepare = 'workspacePair.prepare';
  static const consent = 'workspacePair.consent';
  static const link = 'workspacePair.link';
  static const reverse = 'workspacePair.reverse';
  static const grant = 'workspacePair.grant';
  static const abort = 'workspacePair.abort';
  static const consentTimeout = Duration(minutes: 2);
  static const connectTimeout = Duration(seconds: 50);

  static bool offered(Object? value) => value is int && value == version;

  static bool validId(String id) => RegExp(r'^[0-9a-f]{64}$').hasMatch(id);
  static bool validAttempt(String id) =>
      RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id);

  static const rejected = LinkRemoteException(
    LinkErrors.rejected,
    'Mutual workspace pairing could not be completed',
  );
}

/// The ordered identities of both standard workspace connections.
class DesktopPairBinding {
  const DesktopPairBinding({
    required this.attempt,
    required this.forwardHost,
    required this.forwardClient,
    required this.reverseHost,
    required this.reverseClient,
  });

  final String attempt, forwardHost, forwardClient, reverseHost, reverseClient;

  String get reverseCode => safetyCode(
    keyOfDeviceId(reverseHost)!,
    keyOfDeviceId(reverseClient)!,
  ).join('  ');

  bool get valid {
    final ids = {forwardHost, forwardClient, reverseHost, reverseClient};
    return DesktopMutualPairing.validAttempt(attempt) &&
        ids.length == 4 &&
        ids.every(DesktopMutualPairing.validId);
  }

  Map<String, Object?> toJson() => {
    'attempt': attempt,
    'forwardHost': forwardHost,
    'forwardClient': forwardClient,
    'reverseHost': reverseHost,
    'reverseClient': reverseClient,
  };

  bool matches(Object? other) =>
      other is Map &&
      other.length == 5 &&
      toJson().entries.every((entry) => other[entry.key] == entry.value);
}

/// The return route comes from the already authenticated forward request.
/// Use only locally configured relays and numeric socket addresses, just as
/// for the existing link transport. Display metadata is never authorization.
class DesktopReturnRoute {
  const DesktopReturnRoute(this.address, {required this.direct});

  final LinkAddress address;
  final bool direct;

  static DesktopReturnRoute? decode(
    Object? json, {
    required List<String> allowedRelays,
  }) {
    if (json
        case {
          'id': final String id,
          'direct': final bool direct,
          'addrs': final List<Object?> addrs,
          'relays': final List<Object?> relays,
        }
        when DesktopMutualPairing.validId(id) &&
            addrs.length <= 8 &&
            relays.length <= 16) {
      return DesktopReturnRoute(
        LinkAddress(
          id,
          addrs: addrs.whereType<String>().where(_socketAddress).toList(),
          relays: direct
              ? const []
              : relays
                    .whereType<String>()
                    .where(allowedRelays.contains)
                    .toList(),
        ),
        direct: direct,
      );
    }
    return null;
  }

  // Iroh parses these as socket addresses as well. Reject names and malformed
  // addresses before passing remote input to the transport.
  static bool _socketAddress(String address) {
    final match = RegExp(
      r'^(?:\[([0-9a-fA-F:]+)\]|(\d{1,3}(?:\.\d{1,3}){3})):(\d{1,5})$',
    ).firstMatch(address);
    if (match == null) return false;
    final port = int.parse(match[3]!);
    if (port == 0 || port > 65535) return false;
    if (match[2] case final ipv4?) {
      return ipv4.split('.').every((part) => int.parse(part) <= 255) &&
          !ipv4.startsWith('127.') &&
          !ipv4.startsWith('0.');
    }
    final ipv6 = match[1]!.toLowerCase();
    return ipv6.contains(':') &&
        ipv6.length <= 39 &&
        ipv6 != '::' &&
        ipv6 != '::1' &&
        !ipv6.startsWith('::ffff:');
  }
}
