import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

/*
 Project-level Gradle (Kotlin DSL)
 - Keeps buildscript repositories so AGP/Kotlin/google-services classpath can be resolved.
 - Adds TransistorSoft AAR maven repo for flutter_background_geolocation / background_fetch.
*/

buildscript {
    repositories {
        // Needed to resolve Android Gradle Plugin / Kotlin / google-services classpath
        google()
        mavenCentral()

        // TransistorSoft native AARs required by flutter_background_geolocation / background_fetch
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Gradle plugin portal sometimes required
        maven { url = uri("https://plugins.gradle.org/m2/") }

        // Flutter plugin artifact mirror (helps plugin AAR resolution)
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }

    dependencies {
        // Match versions to your Flutter/AGP compatibility
        classpath("com.android.tools.build:gradle:8.4.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        // Standard repos
        google()
        mavenCentral()

        // Optional local Maven repo
        mavenLocal()

        // TransistorSoft native AARs (important)
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // Gradle plugin repo (sometimes required for some plugins)
        maven { url = uri("https://plugins.gradle.org/m2/") }

        // Flutter plugin artifact mirror
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

/**
 * Optional: relocate build/ out of android/ to keep repo cleaner.
 * Remove or keep as you prefer.
 */
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

/**
 * Ensure Android library subprojects have compileSdk/minSdk set.
 */
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure(LibraryExtension::class.java) {
            compileSdk = 36
            defaultConfig {
                minSdk = 21
            }
            // Optional pinned NDK version if you need one
            ndkVersion = "27.0.12077973"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
