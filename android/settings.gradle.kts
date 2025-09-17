import org.gradle.api.initialization.resolve.RepositoriesMode

pluginManagement {
    // Flutter SDK plugin loader (keep as-is for Flutter)
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // Used to resolve gradle plugins (Android Gradle plugin, Kotlin plugin, etc.)
        google()
        mavenCentral()
        gradlePluginPortal()
        // JitPack for some third-party libs
        maven { url = uri("https://jitpack.io") }
    }
}

dependencyResolutionManagement {
  repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
  repositories {
    google()
    mavenCentral()
    // Flutter plugin mirror
    maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    // JitPack for some GitHub-hosted libs (ucrop, etc)
    maven { url = uri("https://jitpack.io") }
    // Gradle plugin maven (plugins might publish artifacts here)
    maven { url = uri("https://plugins.gradle.org/m2/") }
  }
}


plugins {
    // Keep this in settings; actual plugin application happens in project-level files / subprojects
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
}

include(":app")
