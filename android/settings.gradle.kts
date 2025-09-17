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
    // PREFER_SETTINGS means the settings repositories will be used instead of project repositories.
    // This avoids the "repositories declared in build.gradle are ignored" confusion.
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)

    repositories {
        google()
        mavenCentral()

        // Flutter plugin AAR mirror (important for some Flutter plugin artifacts)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }

        // JitPack (ucrop, some github hosted libs)
        maven { url = uri("https://jitpack.io") }

        // TransistorSoft AARs (background geolocation / background fetch) — keep as fallback.
        // NOTE: you've seen an S3 error in your browser (bucket may be gone). If this URL 404s,
        // you'll need to vendor the AARs locally or use a plugin version that bundles them.
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Sometimes plugin authors publish to plugin repo; keep plugin repo too.
        maven { url = uri("https://plugins.gradle.org/m2/") }
    }
}

plugins {
    // Keep this in settings; actual plugin application happens in project-level files / subprojects
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
}

include(":app")
