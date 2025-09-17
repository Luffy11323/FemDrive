import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

buildscript {
    // repositories here so classpath plugins (AGP, Kotlin, google-services) can be resolved reliably
    repositories {
        google()
        mavenCentral()

        // TransistorSoft native AARs required by flutter_background_geolocation / background_fetch
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Gradle plugin portal (sometimes needed)
        maven { url = uri("https://plugins.gradle.org/m2/") }

        // Flutter plugin artifact mirror
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }

    dependencies {
        // Android Gradle Plugin
        classpath("com.android.tools.build:gradle:8.4.2")
        // Kotlin
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
        // Google Services (Firebase)
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()

        // TransistorSoft native AARs
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Gradle plugin repo
        maven { url = uri("https://plugins.gradle.org/m2/") }

        // Flutter's plugin mirror (important for some Flutter plugin AARs)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

/**
 * Optional: relocate build/ out of android/ to keep repo cleaner.
 * Keep this if you were already using it.
 */
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

/**
 * Critical safety net: ensure all Android library subprojects (Flutter plugins)
 * have explicit compileSdk/minSdk so they don't rely on the old flutter.* shim.
 */
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure(LibraryExtension::class.java) {
            compileSdk = 36
            defaultConfig {
                minSdk = 21
            }
            // Keep your pinned NDK for native plugins (optional)
            ndkVersion = "27.0.12077973"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
