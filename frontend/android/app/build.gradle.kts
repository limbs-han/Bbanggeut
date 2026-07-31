plugins {
    id("com.android.application")
    id("kotlin-parcelize")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI can build without private Firebase configuration. Once the real
// google-services.json is placed in this module, FCM resources are generated.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// pubspec.yaml pins version to 1.0.0+1, so without this every build would ship
// versionCode 1 and versionName 1.0.0. Derive the identity from git instead.
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
val gitShortSha =
    gitOutput("rev-parse", "--short=7", "HEAD")?.takeIf { it.isNotEmpty() }
val gitIsDirty = gitOutput("status", "--porcelain")?.isNotEmpty() == true

android {
    namespace = "com.williamjames.william_james_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.williamjames.william_james_app"
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
            abiFilters += listOf(
                "armeabi-v7a",
                "arm64-v8a",
                "x86_64",
            )
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += "**/libbanuba-ve-yuv.so"
        }
    }

    buildTypes {
        release {
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

val copyBanubaEffects =
    tasks.register<Sync>("copyBanubaEffects") {
        from("../../effects")
        into(layout.buildDirectory.dir("generated/banubaAssets/bnb-resources/effects"))
    }

android.sourceSets.getByName("main").assets.srcDir(
    layout.buildDirectory.dir("generated/banubaAssets"),
)
tasks.named("preBuild").configure {
    dependsOn(copyBanubaEffects)
}

dependencies {
    // Keep every Media3 module on the same version used by video_player_android.
    implementation("androidx.media3:media3-common:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-transformer:1.9.2")
}
