import com.android.build.gradle.LibraryExtension
import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

// NOTE: Do NOT duplicate repository declarations here if you are using
// dependencyResolutionManagement in settings.gradle.kts with PREFER_SETTINGS.
// Keep buildscript minimal and rely on settings pluginManagement for plugin resolution.

buildscript {
    // You can keep this minimal. pluginManagement in settings.gradle.kts will resolve plugins.
    // But Gradle still runs the buildscript block; avoid declaring conflicting repositories here.
    dependencies {
        // If your build requires classpath dependencies, keep them here but resolution will use settings repos.
        // Example kept for compatibility; versions can be updated as needed.
        classpath("com.android.tools.build:gradle:8.4.2")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.9.24")
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    // Do NOT declare repositories here if you've configured dependencyResolutionManagement in settings.
    // If you must declare any project-level repositories, ensure settings.gradle.kts repositoriesMode allows it.
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Ensure plugin library modules compiled with at least a reasonable compileSdk/minSdk (safety net)
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure(LibraryExtension::class.java) {
            compileSdk = 36
            defaultConfig {
                minSdk = 21
            }
            // Optional: pin NDK if required by any native plugin
            ndkVersion = "27.0.12077973"
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
