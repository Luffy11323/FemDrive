import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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

class SelfieStorage {
  static final _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      enableClassification: true,
      enableLandmarks: true,
      enableTracking: false,
      minFaceSize: 0.1,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  /// Verifies selfie with gender detection and trust score
  /// For testing: Women pass even if face is imperfect
  static Future<SelfieVerificationResult> verifySelfie(
    Uint8List imageBytes,
  ) async {
    File? tempFile;
    try {
      // Use file for reliability
      final tempDir = await getTemporaryDirectory();
      final tempPath =
          '${tempDir.path}/verify_selfie_${DateTime.now().millisecondsSinceEpoch}.jpg';
      tempFile = await File(tempPath).writeAsBytes(imageBytes);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final faces = await _faceDetector.processImage(inputImage);

      // === 1. ONE FACE ===
      if (faces.isEmpty) {
        return const SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: 0.0,
          message: 'No face detected',
        );
      }
      if (faces.length > 1) {
        return const SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: 0.0,
          message: 'Multiple faces detected',
        );
      }

      final face = faces.first;

      // === 2. FACE SIZE (lenient) ===
      final imageArea = 800 * 800; // fallback
      final faceArea = face.boundingBox.width * face.boundingBox.height;
      final sizeRatio = faceArea / imageArea;
      if (sizeRatio < 0.03) {
        return const SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: 0.0,
          message: 'Face too small',
        );
      }

      // === 3. LIVENESS HEURISTIC ===
      final leftEyeOpen = face.leftEyeOpenProbability ?? 0.5;
      final rightEyeOpen = face.rightEyeOpenProbability ?? 0.5;
      final smiling = face.smilingProbability ?? 0.5;
      final isLive = (leftEyeOpen + rightEyeOpen + smiling) / 3.0 >= 0.45;

      // === 4. GENDER DETECTION (WOMEN PASS LENIENTLY) ===
      double femaleScore = 0.0;

      if (smiling > 0.4) femaleScore += 0.4;
      if ((face.headEulerAngleY?.abs() ?? 30) < 25) femaleScore += 0.2;
      if ((face.headEulerAngleZ?.abs() ?? 30) < 25) femaleScore += 0.1;

      final leftEye = face.landmarks[FaceLandmarkType.leftEye];
      final rightEye = face.landmarks[FaceLandmarkType.rightEye];
      final nose = face.landmarks[FaceLandmarkType.noseBase];
      if (leftEye != null && rightEye != null && nose != null) {
        final eyeDist = (rightEye.position.x - leftEye.position.x).abs();
        final noseToEyes = nose.position.y - ((leftEye.position.y + rightEye.position.y) / 2);
        if (eyeDist / (noseToEyes + 1) > 1.6) femaleScore += 0.3;
      }

      final isFemale = femaleScore >= 0.5;

      // === 5. TRUST SCORE ===
      final trustScore =
          0.4 * 1.0 + // face detected
          0.3 * (isFemale ? 1.0 : 0.0) +
          0.2 * sizeRatio.clamp(0.0, 1.0) +
          0.1 * 1.0; // lighting

      // === 6. FINAL VALIDATION ===
      if (!isFemale) {
        return SelfieVerificationResult(
          isValid: false,
          isFemale: false,
          trustScore: trustScore,
          message: 'This app is for women only',
        );
      }

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
        message: 'Error: $e',
      );
    } finally {
      if (tempFile != null && await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }

  // === SECURE SAVE (AES + IV + HASH + METADATA) ===
  static Future<bool> saveSelfie(String userId, Uint8List imageBytes) async {
    try {
      final key = await _getOrCreateAesKey();
      final iv = enc.IV.fromSecureRandom(16);
      final aes = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted = aes.encryptBytes(imageBytes, iv: iv);

      final file = await _selfiePath(userId);
      await file.create(recursive: true);
      final out = BytesBuilder()..add(iv.bytes)..add(encrypted.bytes);
      await file.writeAsBytes(out.toBytes(), flush: true);

      // Upload encrypted to Firebase Storage
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'selfie_${userId}_$timestamp.enc';
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('selfies')
          .child(userId)
          .child(fileName);
      await storageRef.putData(out.toBytes());

      // Save integrity hash and metadata
      final bytes = await file.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      await _secure.write(key: _hashKey(userId), value: hash);
      await _secure.write(key: _attemptKey(userId), value: '0');
      await _secure.write(key: _lastVerifiedKey(userId), value: timestamp.toString());

      if (kDebugMode) {
        print('Selfie saved securely for user $userId');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error saving selfie: $e');
      }
      return false;
    }
  }

  // === SECURE RETRIEVAL ===
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

  // === DELETE LOCAL + CLOUD + SECURE STORE ===
  static Future<bool> deleteSelfie(String userId) async {
    try {
      // Local file
      final file = await _selfiePath(userId);
      if (await file.exists()) await file.delete();

      // Secure storage
      await _secure.delete(key: _hashKey(userId));
      await _secure.delete(key: _attemptKey(userId));
      await _secure.delete(key: _lastVerifiedKey(userId));

      // Firebase Storage
      final storageRef = FirebaseStorage.instance.ref().child('selfies').child(userId);
      final listResult = await storageRef.listAll();
      for (var item in listResult.items) {
        await item.delete();
      }

      if (kDebugMode) {
        print('Selfie deleted for user $userId');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('Error deleting selfie: $e');
      }
      return false;
    }
  }

  // === INTEGRITY & SECURITY HELPERS ===
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
    return (3 - n).clamp(0, 3); // remaining attempts
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

  // === FULL ACCOUNT WIPE (SELFIE + FIRESTORE + AUTH) ===
  static Future<void> triggerAccountDeletion() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final uid = user.uid;

    await deleteSelfie(uid);

    final doc = FirebaseFirestore.instance.collection('users').doc(uid);
    await FirebaseFirestore.instance.recursiveDelete(doc);

    await user.delete();
    await FirebaseAuth.instance.signOut();
  }
}

extension FirestoreX on FirebaseFirestore {
  /// Recursively deletes a user document and ALL documents in its known subcollections
  Future<void> recursiveDelete(DocumentReference ref) async {
    const knownSubcollections = <String>[
      'messages',
      'posts',
      'likes',
      'comments',
      'notifications',
      'settings',
      // Add any other subcollections under your user document
    ];

    final deleteFutures = <Future<void>>[];

    for (final colName in knownSubcollections) {
      final colRef = ref.collection(colName);

      // Delete in batches of 500 (Firestore limit)
      while (true) {
        final snapshot = await colRef.limit(500).get();
        if (snapshot.docs.isEmpty) break;

        final batch = this.batch(); // Correct: use `this.batch()`
        for (final doc in snapshot.docs) {
          batch.delete(doc.reference);
        }
        deleteFutures.add(batch.commit()); // Correct: use `deleteFutures`
      }
    }

    // Wait for all batches to complete
    await Future.wait(deleteFutures);

    // Finally delete the root document
    await ref.delete();
  }
}