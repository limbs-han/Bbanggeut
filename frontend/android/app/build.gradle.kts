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

val banubaAssetRoot = layout.buildDirectory.dir("generated/banubaAssets/bnb-resources")

val copyBanubaEffects =
    tasks.register<Sync>("copyBanubaEffects") {
        from("../../effects")
        into(banubaAssetRoot.map { it.dir("effects") })

        // **우리가 넣은 효과 이름을 적어 둔다.**
        //
        // Banuba SDK(effect-player-adapter)도 자기 AAR에 `bnb-resources/effects`를
        // 넣어 온다(BeautyBGEffects 등). 에셋 경로가 같아 합쳐지기 때문에, 런타임에
        // 폴더만 봐서는 우리 것과 SDK 것을 구분할 수 없다. 빌드 때 목록을 남겨
        // 두면 이름을 코드에 박지 않고도 우리 것만 고를 수 있다.
        doLast {
            // 효과인지 가르는 기준은 **BanubaMaskEffectHelper와 같아야 한다.**
            // 한쪽만 고치면 목록에는 뜨는데 우리 것이 아니라고 걸러지거나,
            // 그 반대가 된다. `config.js`는 동작 스크립트, `config.json`은
            // 장면이고 둘 중 하나만 있어도 효과다 — 스크립트 없이 장면만
            // 있는 효과가 실제로 있다(scene_4_faces).
            val names = file("../../effects")
                .listFiles()
                ?.filter {
                    it.isDirectory &&
                        (File(it, "config.js").isFile || File(it, "config.json").isFile)
                }
                ?.map { it.name }
                ?.sorted()
                .orEmpty()
            banubaAssetRoot.get().asFile.resolve("bundled_effects.txt")
                .writeText(names.joinToString(separator = System.lineSeparator()))
        }
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

    // Banuba Video Editor 모듈. **런타임에는 이미 들어와 있다** —
    // ve_sdk_flutter 플러그인이 같은 버전(1.53.0)을 implementation으로 끌어온다.
    // 다만 implementation은 컴파일 클래스패스로 새어 나오지 않아서, 앱 코드가
    // Playback/Effects API를 직접 부르려면 여기에 한 번 더 적어야 한다.
    //
    // 그래서 compileOnly다 — APK에 두 번 들어가지 않고, 버전도 플러그인이 정한
    // 하나만 남는다. 이 값을 플러그인과 다르게 올리면 런타임에 없는 심볼을
    // 부르게 되므로 반드시 같이 움직여야 한다.
    //
    // 저장소(nexus.banuba.net)는 플러그인이 rootProject.allprojects에 등록하므로
    // 여기서 따로 선언하지 않는다. Face AR 코어(bnb_sdk_version=1.18.+)와는
    // 별개의 축이며 섞지 않는다.
    val banubaVeSdkVersion = "1.53.0"
    compileOnly("com.banuba.sdk:core-sdk:$banubaVeSdkVersion")
    compileOnly("com.banuba.sdk:ve-sdk:$banubaVeSdkVersion")
    compileOnly("com.banuba.sdk:ve-effects-sdk:$banubaVeSdkVersion")
    compileOnly("com.banuba.sdk:ve-playback-sdk:$banubaVeSdkVersion")
    compileOnly("com.banuba.sdk:ve-export-sdk:$banubaVeSdkVersion")
    // 플레이어는 Koin에서 꺼내야 한다(생성자에 필요한 팩토리가 internal이다).
    // Banuba 모듈이 런타임에 같은 버전을 이미 싣고 있으므로 여기서도 compileOnly다.
    compileOnly("io.insert-koin:koin-android:4.1.1")
}
