import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:bip340/bip340.dart' as schnorr;
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hex/hex.dart';
import 'package:yana/utils/platform_util.dart';

import '../main.dart';
import 'client_utils/keys.dart';

class Event {
  /// Creates a new Nostr event.
  ///
  /// [pubKey] is the author's public key.
  /// [kind] is the event kind.
  /// [tags] is a JSON object of event tags.
  /// [content] is an arbitrary string.
  ///
  /// Nostr event `id` and `created_at` fields are calculated automatically.
  ///
  /// An [ArgumentError] is thrown if [pubKey] is invalid.
  Event(this.pubKey, this.kind, this.tags, this.content,
      {DateTime? publishAt}) {
    if (!keyIsValid(pubKey)) {
      throw ArgumentError.value(pubKey, 'pubKey', 'Invalid key');
    }
    if (publishAt != null) {
      createdAt = publishAt.millisecondsSinceEpoch ~/ 1000;
    } else {
      createdAt = _secondsSinceEpoch();
    }
    id = _getId(pubKey, createdAt, kind, tags, content);
  }

  Event._(this.id, this.pubKey, this.createdAt, this.kind, this.tags,
      this.content, this.sig);

  factory Event.fromJson(Map<String, dynamic> data) {
    final id = data['id'] as String;
    final pubKey = data['pubkey'] as String;
    final createdAt = data['created_at'] as int;
    final kind = data['kind'] as int;
    final tags = data['tags'];
    final content = data['content'] as String;
    final sig = data['sig'] as String;

    return Event._(id, pubKey, createdAt, kind, tags, content, sig);
  }

  /// The event ID is a 32-byte SHA256 hash of the serialised event data.
  String id = '';

  /// The event author's public key.
  final String pubKey;

  /// Event creation timestamp in Unix time.
  late int createdAt;

  /// Event kind identifier (e.g. text_note, set_metadata, etc).
  final int kind;

  /// A JSON array of event tags.
  List<dynamic> tags; // Modified by proof-of-work

  /// Event content.
  final String content;

  /// 64-byte Schnorr signature of [Event.id].
  String sig = '';

  /// Relay that an event was received from
  List<String> sources = [];

  /// Returns the Event object as a JSON object
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'pubkey': pubKey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig
    };
  }

  void doProofOfWork(int difficulty) {
    if (difficulty < 0) {
      throw ArgumentError("PoW difficulty can't be negative", 'difficulty');
    }
    if (difficulty > 0) {
      final difficultyInBytes = (difficulty / 8).ceil();
      List<dynamic> result = [];
      for (List<dynamic> tag in tags) {
        result.add(tag);
      }
      result.add(["nonce", "0", difficulty.toString()]);
      tags = result;
      int nonce = 0;
      do {
        const int nonceIndex = 1;
        tags.last[nonceIndex] = (++nonce).toString();
        id = _getId(pubKey, createdAt, kind, tags, content);
      } while (_countLeadingZeroBytes(id) < difficultyInBytes);
    }
  }

  void sign(String privateKey) {
    if (keyIsValid(privateKey)) {
      final aux = getRandomHexString();
      sig = schnorr.sign(privateKey, id, aux);
    }
  }

  bool get isValid {
    // Validate event data
    if (id != _getId(pubKey, createdAt, kind, tags, content)) {
      return false;
    }
    return true;
  }

  static int count = 0;
  static int timeSum = 0;
  static Map<int, int?> kindMapCount = {};

  static const platform = MethodChannel('flutter.native/helper');

  Future<bool> get isSigned async {
    if (PlatformUtil.isWeb()) {
      return true;
    }
    count++;
    int? kindCount = kindMapCount[kind];
    kindCount ??= 0;
    kindCount++;
    kindMapCount[kind] = kindCount;
    final startTime = DateTime.now();
    late bool v;
    if (PlatformUtil.isAndroid() && appState != AppLifecycleState.inactive) {
      v = await platform.invokeMethod("verifySignature", {
        "signature": HEX.decode(sig),
        "hash": HEX.decode(id),
        "pubKey": HEX.decode(pubKey)
      });
    } else {
      v = schnorr.verify(pubKey, id, sig);
    }
    final endTime = DateTime.now();

    // Calculate the elapsed time
    final duration = endTime.difference(startTime);
    timeSum+=duration.inMilliseconds;

    double avg = timeSum / count;

    if (kDebugMode) {
      // print("Execution time: ${duration
      //     .inMilliseconds} milliseconds, total count:$count, avgTime:${avg}ms |  kind $kind count $kindMapCount.toString())");
      if (count % 100 == 0) {
        // BotToast.showText(
        //     text: "total count:$count, avgTime:${avg}ms |  kind $kind count $kindMapCount)",
        //     duration: Duration(seconds: 10));
      }
    }
    return v;
  }

  // Individual events with the same "id" are equivalent
  @override
  bool operator ==(other) => other is Event && id == other.id;
  @override
  int get hashCode => id.hashCode;

  static int _secondsSinceEpoch() {
    final now = clock.now();
    final secondsSinceEpoch = now.millisecondsSinceEpoch ~/ 1000;
    return secondsSinceEpoch;
  }

  static String _getId(String publicKey, int createdAt, int kind,
      List<dynamic> tags, String content) {
    final jsonData =
        json.encode([0, publicKey, createdAt, kind, tags, content]);
    final bytes = utf8.encode(jsonData);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  int _countLeadingZeroBytes(String eventId) {
    List<int> bytes = HEX.decode(eventId);
    int zeros = 0;
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) {
        zeros = (i + 1);
      } else {
        break;
      }
    }
    return zeros;
  }

  String? getEId() {
    for (var tag in tags) {
      if (tag.length > 1) {
        var key = tag[0];
        var value = tag[1];

        if (key == "e") {
          return value as String;
        }
      }
    }
    return null;
  }

}
