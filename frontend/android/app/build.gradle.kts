import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

buildscript {
    repositories {
        mavenCentral()
    }
    dependencies {
        classpath("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    }
}

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.darkplayoff.yayma"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_21.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.darkplayoff.yayma"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation("rustls:rustls-platform-verifier:latest.release")
}

repositories {
    rustlsPlatformVerifier()
}

fun RepositoryHandler.rustlsPlatformVerifier(): MavenArtifactRepository {
    @Suppress("UnstableApiUsage")
    val manifestPath = let {
        val dependencyJson = providers.exec {
            workingDir = File(project.rootDir, "../../")
            commandLine("cargo", "metadata", "--format-version", "1", "--filter-platform", "aarch64-linux-android", "--manifest-path", "Cargo.toml")
        }.standardOutput.asText

        val path = Json.decodeFromString<JsonObject>(dependencyJson.get())
            .getValue("packages")
            .jsonArray
            .first { element ->
                element.jsonObject.getValue("name").jsonPrimitive.content == "rustls-platform-verifier-android"
            }.jsonObject.getValue("manifest_path").jsonPrimitive.content

        File(path)
    }

    return maven {
        url = uri(File(manifestPath.parentFile, "maven").path)
        metadataSources.artifact()
    }
}

flutter {
    source = "../.."
}
