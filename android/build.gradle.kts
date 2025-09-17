import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

buildscript {
    // ensure classpath dependencies (AGP/Kotlin/google-services) resolve
    repositories {
        google()
        mavenCentral()
        mavenLocal()

        // TransistorSoft native AARs required by flutter_background_geolocation / background_fetch
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // JitPack (GitHub-hosted libs)
        maven { url = uri("https://jitpack.io") }

        // Flutter plugin AAR mirror
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }

        // Gradle plugin portal (rarely needed)
        maven { url = uri("https://plugins.gradle.org/m2/") }
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.4.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        mavenLocal()

        // TransistorSoft native AARs
        maven { url = uri("https://s3.amazonaws.com/transistorsoft-maven") }

        // JitPack for GitHub-hosted artifacts (flutter_js, ucrop etc)
        maven { url = uri("https://jitpack.io") }

        // Flutter plugin artifact mirror
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }

        // Gradle plugin repo
        maven { url = uri("https://plugins.gradle.org/m2/") }
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
 * Ensure Android library subprojects (Flutter plugins) have explicit compileSdk/minSdk.
 */
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure(LibraryExtension::class.java) {
            compileSdk = 36
            defaultConfig {
                minSdk = 21
            }
            ndkVersion = "27.0.12077973"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
