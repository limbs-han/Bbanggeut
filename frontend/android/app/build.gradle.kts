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
        // flutter_local_notifications가 java.time을 쓴다. 이 스위치가 없으면
        // 앱을 켜 둔 동안 띄우는 포그라운드 알림이 빌드부터 실패한다.
        isCoreLibraryDesugaringEnabled = true
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

dependencies {
    // isCoreLibraryDesugaringEnabled의 짝. flutter_local_notifications용.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // ML Kit GenAI 온디바이스 음성 인식 — 자막의 whisper 대안 경로(MlKitTranscriber.kt).
    // **실험 중이다.** alpha 버전이고, 판정이 끝나면 이 줄과 함께 한쪽을 지운다.
    // implementation인 이유: MlKitTranscriber가 main 소스셋에 있어 release도 컴파일된다.
    implementation("com.google.mlkit:genai-speech-recognition:1.0.0-alpha1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    // 편집 완성본 업로드를 앱 밖에서도 이어가는 백그라운드 작업
    // (EditedVideoUploadWorker.kt). 앱을 꺼도 OS가 마저 올린다.
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // Keep every Media3 module on the same version used by video_player_android.
    implementation("androidx.media3:media3-common:1.9.2")
    implementation("androidx.media3:media3-effect:1.9.2")
    implementation("androidx.media3:media3-transformer:1.9.2")
}
