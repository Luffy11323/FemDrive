# Flutter / Dart
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.view.** { *; }
-dontwarn io.flutter.embedding.**

# Firebase Core
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keepattributes *Annotation*, Signature
-keepclassmembers class * {
    @com.google.firebase.database.IgnoreExtraProperties <fields>;
}

# Firebase Messaging
-keep class com.google.firebase.messaging.FirebaseMessagingService { *; }
-keep class com.google.firebase.iid.FirebaseInstanceIdService { *; }
-keep class com.google.firebase.messaging.RemoteMessage { *; }

# Firebase Auth
-keep class com.google.firebase.auth.** { *; }
-dontwarn com.google.firebase.auth.**

# Firebase Firestore
-keep class com.google.firebase.firestore.** { *; }
-dontwarn com.google.firebase.firestore.**

# Firebase Storage
-keep class com.google.firebase.storage.** { *; }
-dontwarn com.google.firebase.storage.**

# Google Play Services / Maps
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Geolocator & Geocoding
-keep class com.baseflow.** { *; }
-dontwarn com.baseflow.**

# Riverpod (keep annotations)
-keepattributes RuntimeVisibleAnnotations
-keep class **$$Lambda$* { *; }

# JSON (Gson / Jackson / Moshi)
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.google.gson.**

# Prevent removal of model classes (for serialization)
-keepclassmembers class * {
    public <init>(...);
}

# AndroidX
-dontwarn androidx.**
-keep class androidx.** { *; }

# Flutter Local Notifications
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**

# SMS Autofill
-keep class com.sms_autofill.** { *; }
-dontwarn com.sms_autofill.**

# Prevent stripping of R classes
-keepclassmembers class **.R$* {
    public static <fields>;
}

# Keep enums
-keepclassmembers enum * { *; }
