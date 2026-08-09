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

        // 내보내기 파이프라인(media3 오버레이) 계측 테스트용
        // (EditorOverlayExportTest.kt).
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

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
        // 기존 설치본을 지우지 않고 나란히 설치하는 테스트용 릴리즈.
        //
        // flavor가 아니라 buildType인 이유: flavor를 하나라도 만들면
        // `flutter build apk`가 --flavor 없이는 실패해 CI(Jenkinsfile)까지
        // 바뀌어야 한다. buildType은 기존 debug/release 경로를 전혀 건드리지
        // 않고, `gradlew :app:assemblePreview`로만 나온다.
        create("preview") {
            initWith(getByName("release"))
            applicationIdSuffix = ".preview"
            versionNameSuffix = "-preview"
            signingConfig = signingConfigs.getByName("debug")
            // 코드 축소는 끈다. Flutter 플러그인의 R8 설정이 커스텀
            // buildType에는 반쪽만 적용돼 빌드가 깨진다 — 테스트 앱이라
            // 크기·난독화를 챙길 이유도 없다.
            isMinifyEnabled = false
            isShrinkResources = false
            // 플러그인 AAR들은 debug/release 변형만 내놓는다. preview가 없을
            // 때 release 쪽을 쓰게 한다.
            matchingFallbacks += "release"
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

    // 내보내기 파이프라인 계측 테스트(EditorOverlayExportTest.kt) 전용.
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
