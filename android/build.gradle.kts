// android/build.gradle.kts (Project-level)

import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

buildscript {
    // Keep the buildscript block but rely on settings repositories.
    // If a repository is required here, settings.gradle.kts already provides it.
    repositories {
        google()
        mavenCentral()
        // Flutter plugin mirror (ensure plugin AAR resolution)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
    dependencies {
        // Android Gradle Plugin
        classpath("com.android.tools.build:gradle:8.4.2")
        // Kotlin Gradle plugin
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
        // Google services (Firebase) plugin
        classpath("com.google.gms:google-services:4.4.2")
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
 * have explicit compileSdk/minSdk so they don't rely on old defaults.
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

// Clean task to remove old build artifacts
tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }

        // Add the local repository for the background_fetch library
        maven { url = uri("${project(':background_fetch').projectDir}/libs") }
    }
}
