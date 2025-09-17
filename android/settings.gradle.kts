pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // plugin resolution repos
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // Keep FAIL_ON_PROJECT_REPOS to centralize repo configuration and avoid surprises.
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)

    repositories {
        // Standard Android repos
        google()
        mavenCentral()

        // TransistorSoft native AARs required by flutter_background_geolocation / background_fetch
        // (This hosts tsbackgroundfetch, tslocationmanager artifacts.)
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Gradle plugin repo (sometimes required)
        maven { url = uri("https://plugins.gradle.org/m2/") }

        // Flutter plugin artifact mirror (important for some Flutter plugin AARs)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.7.3" apply false
    // START: FlutterFire Configuration
    id("com.google.gms.google-services") version("4.3.15") apply false
    // END: FlutterFire Configuration
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
