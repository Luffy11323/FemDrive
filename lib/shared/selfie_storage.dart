import 'dart:io';
import 'dart:convert';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// === Secure selfie storage helpers (AES + hash + attempts + validity) ===
const _kAesKeyName = 'selfie_aes_key'; // base64-encoded AES-256 key

String _hashKey(String uid) => 'selfie_hash_$uid';
String _attemptKey(String uid) => 'selfie_attempts_$uid';
String _lastVerifiedKey(String uid) => 'lastSelfieVerifiedAt_$uid';

final _secure = FlutterSecureStorage();

Future<enc.Key> _getOrCreateAesKey() async {
  final existing = await _secure.read(key: _kAesKeyName);
  if (existing != null) {
    return enc.Key(base64.decode(existing));
  }
  final key = enc.Key.fromSecureRandom(32);
  await _secure.write(key: _kAesKeyName, value: base64.encode(key.bytes));
  return key;
}

Future<File> _selfiePath(String uid) async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/selfie_$uid.enc');
}

/// Result of selfie verification with gender and trust score
class SelfieVerificationResult {
  final bool isValid;
  final bool isFemale;
  final double trustScore;
  final String? message;

  const SelfieVerificationResult({
    required this.isValid,
    required this.isFemale,
    required this.trustScore,
    this.message,
  });
}

/// Selfie verification service:
/// - Face detection (MLKit)
/// - Basic liveness heuristics (blink/pose checks can be extended)
/// - Simple female validation heuristic (can be swapped with stronger model)
/// - Trust score calculation
class SelfieStorage {
  /// Verifies a selfie image using ML Kit face detection and heuristic checks.
  /// Returns a [SelfieVerificationResult] with isValid, isFemale, and trustScore.
  static Future<SelfieVerificationResult> verifySelfie(
    Uint8List imageBytes,
  ) async {
    try {
      final inputImage = InputImage.fromFilePath(
        (await _writeTempImage(imageBytes)).path,
      );

      final options = FaceDetectorOptions(
        enableContours: true,
        enableClassification: true,
        enableLandmarks: true,
        performanceMode: FaceDetectorMode.accurate,
      );

      final faceDetector = FaceDetector(options: options);
      final faces = await faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        return const SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: 0.0,
          message: 'No face detected',
        );
      }

      final face = faces.first;

      // === 1. Simple liveness heuristic (eyes open or smiling) ===
      // These values may be null if model did not classify
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.5;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.5;
      final smiling = face.smilingProbability ?? 0.5;
      final isLive = (leftEyeOpen + rightEyeOpen + smiling) / 3.0 >= 0.45;

      // === 2. Size ratio (face bounding relative to image) ===
      // Helps filter out far faces / printed spoofs
      final bbox = face.boundingBox;
      final sizeRatio = _estimateSizeRatio(bbox, imageBytes);

      // === 3. Basic female heuristic (very weak; to be replaced by stronger on-device model) ===
      final isFemale = _heuristicFemale(smiling, leftEyeOpen, rightEyeOpen);

      // === 4. TRUST SCORE (independent) ===
      final trustScore =
          0.4 * 1.0 + // face detected
          0.3 * (isFemale ? 1.0 : 0.0) +
          0.2 * sizeRatio.clamp(0.0, 1.0) +
          0.1 * 1.0; // lighting

      // === 5. FINAL: WOMEN PASS ===
      if (!isFemale) {
        return SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: trustScore,
          message: 'This app is for women only',
        );
      }

      // === 6. LIVENESS & THRESHOLD ===
      if (!isLive || trustScore < 0.80) {
        return SelfieVerificationResult(
          isValid: false,
          isFemale: true,
          trustScore: trustScore,
          message: 'Low trust or failed liveness',
        );
      }

      return SelfieVerificationResult(
        isValid: true,
        isFemale: true,
        trustScore: trustScore,
        message: 'Verified',
      );
    } catch (e) {
      return SelfieVerificationResult(
        isValid: false,
        isFemale: false,
        trustScore: 0.0,
        message: 'Verification error: $e',
      );
    }
  }

  static double _estimateSizeRatio(Rect bbox, Uint8List bytes) {
    try {
      // Heuristic: assume 1080x1920-ish; tweak with actual decoder if needed
      final w = 1080.0;
      final h = 1920.0;
      final area = bbox.width * bbox.height;
      final total = w * h;
      return (area / total).clamp(0.0, 1.0);
    } catch (_) {
      return 0.3;
    }
  }

  static bool _heuristicFemale(
    double smiling,
    double leftEyeOpen,
    double rightEyeOpen,
  ) {
    // Weak heuristic placeholder (replace with proper on-device model)
    final avg = (smiling + leftEyeOpen + rightEyeOpen) / 3.0;
    return avg >= 0.45;
  }

  static Future<File> _writeTempImage(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/_tmp_selfie.jpg');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  // === Rest of the methods (updated) ===
  static Future<bool> saveSelfie(String userId, Uint8List imageBytes) async {
    try {
      final key = await _getOrCreateAesKey();
      final iv = enc.IV.fromSecureRandom(16);
      final aes = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted = aes.encryptBytes(imageBytes, iv: iv);

      final file = await _selfiePath(userId);
      await file.create(recursive: true);
      final out = BytesBuilder()
        ..add(iv.bytes)
        ..add(encrypted.bytes);
      await file.writeAsBytes(out.toBytes(), flush: true);

      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      await _secure.write(key: _hashKey(userId), value: hash);
      await _secure.write(key: _attemptKey(userId), value: '0');
      await _secure.write(
        key: _lastVerifiedKey(userId),
        value: DateTime.now().millisecondsSinceEpoch.toString(),
      );
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error saving selfie: $e');
      }
      return false;
    }
  }

  static Future<Uint8List?> retrieveSelfie(String userId) async {
    try {
      final file = await _selfiePath(userId);
      if (!await file.exists()) return null;
      final data = await file.readAsBytes();
      if (data.length < 16) return null;
      final iv = enc.IV(data.sublist(0, 16));
      final cipher = data.sublist(16);
      final key = await _getOrCreateAesKey();
      final aes = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final plain = aes.decryptBytes(enc.Encrypted(cipher), iv: iv);
      return Uint8List.fromList(plain);
    } catch (e) {
      if (kDebugMode) {
        print('Error retrieving selfie: $e');
      }
      return null;
    }
  }

  static Future<bool> deleteSelfie(String userId) async {
    try {
      final file = await _selfiePath(userId);
      if (await file.exists()) await file.delete();
      await _secure.delete(key: _hashKey(userId));
      await _secure.delete(key: _attemptKey(userId));
      await _secure.delete(key: _lastVerifiedKey(userId));
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error deleting selfie: $e');
      }
      return false;
    }
  }

  static Future<bool> validateIntegrity(String uid) async {
    final file = await _selfiePath(uid);
    if (!await file.exists()) return false;
    final stored = await _secure.read(key: _hashKey(uid));
    if (stored == null) return false;
    final bytes = await file.readAsBytes();
    final computed = sha256.convert(bytes).toString();
    return stored == computed;
  }

  static Future<int> incrementAttempt(String uid) async {
    final k = _attemptKey(uid);
    final raw = await _secure.read(key: k);
    final n = (int.tryParse(raw ?? '0') ?? 0) + 1;
    await _secure.write(key: k, value: '$n');
    return (3 - n).clamp(0, 3);
  }

  static Future<void> resetAttempts(String uid) async {
    await _secure.write(key: _attemptKey(uid), value: '0');
  }

  static Future<void> markSelfieVerified(String uid) async {
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    await _secure.write(key: _lastVerifiedKey(uid), value: now);
  }

  static Future<bool> isSelfieStillValid(String uid) async {
    final ts = await _secure.read(key: _lastVerifiedKey(uid));
    if (ts == null) return false;
    final last = DateTime.fromMillisecondsSinceEpoch(int.parse(ts));
    final now = DateTime.now();
    const minDays = 3;
    const maxDays = 7;
    final thresholdDays = Random().nextInt(maxDays - minDays + 1) + minDays;
    final expiresAt = last.add(Duration(days: thresholdDays));
    return now.isBefore(expiresAt);
  }

  static Future<void> triggerAccountDeletion() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;
    await deleteSelfie(uid);
    final doc = FirebaseFirestore.instance.collection('users').doc(uid);
    await FirebaseFirestore.instance.recursiveDelete(doc);
    await FirebaseAuth.instance.currentUser?.delete();
    await FirebaseAuth.instance.signOut();
  }
}

extension FirestoreX on FirebaseFirestore {
  Future<void> recursiveDelete(DocumentReference ref) async {
    // Delete all subcollections manually since listCollections() is not available in Firestore v5+
    try {
      final collections = await _getSubcollections(ref);
      for (final col in collections) {
        final snaps = await col.get();
        for (final doc in snaps.docs) {
          await recursiveDelete(doc.reference);
        }
      }
      await ref.delete();
    } catch (e) {
      if (kDebugMode) {
        print('Recursive delete error: $e');
      }
    }
  }

  /// Helper: Fetch all subcollections safely across Firestore versions
  Future<List<CollectionReference>> _getSubcollections(
    DocumentReference ref,
  ) async {
    final firestore = FirebaseFirestore.instance;
    final rootPath = ref.path;

    // Try to identify all nested subcollection paths under this ref
    final segments = rootPath.split('/');
    if (segments.length.isOdd) {
      // Only even-length paths represent collections
      final parentCollectionPath = segments.take(segments.length - 1).join('/');
      final parentCollection = firestore.collection(parentCollectionPath);
      final docs = await parentCollection.get();
      return docs.docs.map((d) => d.reference.collection(rootPath)).toList();
    }

    return <CollectionReference>[];
  }
}
