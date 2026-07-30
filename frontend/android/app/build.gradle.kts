plugins {
    id("com.android.application")
    id("kotlin-parcelize")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

<<<<<<< HEAD
// CI can build without private Firebase configuration. Once the real
// google-services.json is placed in this module, FCM resources are generated.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}
=======
// pubspec.yaml pins version to 1.0.0+1, so without this every build would ship
// versionCode 1 and versionName 1.0.0. Two APKs built minutes apart were then
// indistinguishable on-device and a stale install looked identical to a fresh
// one. Derive the identity from git instead: the commit count is monotonic, and
// the short SHA says exactly which code is on the phone.
//
// Falls back to the pubspec values when git is unavailable (no repo, git not on
// PATH), so an archive build still succeeds.
fun gitOutput(vararg args: String): String? =
    try {
        val process = ProcessBuilder(listOf("git", *args))
            .directory(rootDir)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText().trim()
        if (process.waitFor() == 0) output else null
    } catch (ignored: Exception) {
        null
    }

val gitCommitCount = gitOutput("rev-list", "--count", "HEAD")?.toIntOrNull()
val gitShortSha = gitOutput("rev-parse", "--short=7", "HEAD")?.takeIf { it.isNotEmpty() }
// Uncommitted changes are flagged: a build from a dirty tree is not reproducible
// from the SHA alone, and that is worth seeing in `adb shell dumpsys package`.
val gitIsDirty = gitOutput("status", "--porcelain")?.isNotEmpty() == true
>>>>>>> d61491c5d408c494d63fb837cdb9a1bd755acbd5

android {
    namespace = "com.williamjames.william_james_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.williamjames.william_james_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = gitCommitCount ?: flutter.versionCode
        versionName = if (gitShortSha != null) {
            "${flutter.versionName}+${gitCommitCount ?: 0}.$gitShortSha" +
                if (gitIsDirty) ".dirty" else ""
        } else {
            flutter.versionName
        }

        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Keep every Media3 module on the same version used by video_player_android.
    implementation("androidx.media3:media3-common:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-transformer:1.9.2")
}
