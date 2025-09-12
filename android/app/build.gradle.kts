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
    namespace = "com.company.FemDrive"

    // Pin explicit SDKs (avoid plugin subproject issues)
    compileSdk = 34

    // Set NDK version to highest needed (Fixes mismatch)
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // Desugaring for newer Java APIs
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.company.FemDrive"

        // Prefer explicit values; fall back to project props if provided
        minSdk = (project.findProperty("MIN_SDK_VERSION")?.toString()?.toInt() ?: 21)
        targetSdk = (project.findProperty("TARGET_SDK_VERSION")?.toString()?.toInt() ?: 34)

        // Versioning: use explicit fallbacks if custom props not set
        versionCode = (
            project.findProperty("VERSION_CODE")?.toString()?.toInt()
                ?: project.findProperty("flutter.versionCode")?.toString()?.toInt()
                ?: 1
        )
        versionName = (
            project.findProperty("VERSION_NAME")?.toString()
                ?: project.findProperty("flutter.versionName")?.toString()
                ?: "1.0"
        )
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

    // Firebase BOM for version alignment
    implementation(platform("com.google.firebase:firebase-bom:33.1.1"))

    // Firebase SDKs
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-storage")
}
