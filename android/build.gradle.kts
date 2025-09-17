import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

buildscript {
    // NOTE: repository resolution is centralized in settings.gradle.kts (dependencyResolutionManagement)
    // Do not declare repositories here when using RepositoriesMode.FAIL_ON_PROJECT_REPOS.
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
    // Intentionally left blank for repositories — settings.gradle.kts controls repositories centrally.
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
