plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.company.FemDrive"
    compileSdk = 36
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
        applicationId = "com.company.FemDrive"
        minSdk = (project.findProperty("MIN_SDK_VERSION")?.toString()?.toInt() ?: 21)
        targetSdk = (project.findProperty("TARGET_SDK_VERSION")?.toString()?.toInt() ?: 34)
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
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:33.1.1"))
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-storage")
}

// ADD THIS SECTION - Force plugin repositories to be ignored
configurations.all {
    resolutionStrategy {
        // Prevent plugins from using dynamic versions (+)
        eachDependency {
            if (requested.group == "com.transistorsoft") {
                // These versions should exist in the plugin's bundled libs
                when (requested.name) {
                    "tsbackgroundfetch" -> useVersion("0.7.3")
                    "tslocationmanager" -> useVersion("3.18.3")
                }
            }
        }
    }
}