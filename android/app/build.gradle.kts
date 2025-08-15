plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.Femdrive"
    compileSdk = flutter.compileSdkVersion

    // Set NDK version to highest needed (Fixes mismatch)
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {

minSdk = (project.findProperty("MIN_SDK_VERSION")?.toString()?.toInt()
    ?: flutter.minSdkVersion)

targetSdk = (project.findProperty("TARGET_SDK_VERSION")?.toString()?.toInt()
    ?: flutter.targetSdkVersion)

versionCode = (project.findProperty("VERSION_CODE")?.toString()?.toInt()
    ?: flutter.versionCode)

versionName = (project.findProperty("VERSION_NAME")?.toString()
    ?: flutter.versionName)

    }

    buildTypes {
        release {
            // Enable code shrinking & optimization
            isMinifyEnabled = true
            isShrinkResources = true

            // Use default + custom ProGuard rules
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // TODO: Replace with your real signing config before publishing
            signingConfig = signingConfigs.getByName("debug")
        }
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required for Java 8+ API desugaring
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
