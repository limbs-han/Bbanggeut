package com.williamjames.william_james_app

import android.content.Context
import android.net.Uri
import android.util.Log
import java.io.File

/// assets에 들어 있는 얼굴 효과를 EffectPlayer가 읽을 수 있는 **파일 경로**로
/// 꺼내 놓는다.
///
/// **왜 꺼내야 하나**: 효과 폴더는 `config.js`와 여러 리소스로 이루어져 있고,
/// EffectPlayer는 이걸 파일 시스템 경로로 연다. APK 안의 asset은 파일이 아니라서
/// 그대로 넘길 수 없다.
///
/// 효과는 `android/app/build.gradle.kts`의 `copyBanubaEffects`가 빌드 때
/// `assets/bnb-resources/effects/<이름>`으로 넣어 둔다. 여기서는 그걸 앱 내부
/// 저장소로 한 번만 편다 — 이미 펴 놨으면 그대로 쓴다.
internal class BanubaMaskEffectHelper(private val context: Context) {
    companion object {
        private const val TAG = "BanubaMask"
        private const val ASSET_ROOT = "bnb-resources/effects"

        /// 효과가 자기를 설명하는 두 파일. **둘 중 하나만 있어도 효과다.**
        ///
        /// `config.js`는 동작 스크립트, `config.json`은 장면(어떤 메시를 어느
        /// 얼굴에 붙이는지)이다. 예전에는 스크립트만 보고 갈랐는데, Banuba
        /// 효과는 스크립트 없이 장면만으로도 성립한다 — 얼굴을 넷까지 잡는
        /// `scene_4_faces`가 그렇다. 스크립트만 찾으면 그런 효과는 목록에
        /// 아예 뜨지 않는다. 공용 리소스 폴더(`images`·`meshes`)는 둘 다 없어서
        /// 가려내는 목적은 그대로 지켜진다.
        private const val EFFECT_SCRIPT = "config.js"
        private const val EFFECT_SCENE = "config.json"
        private const val EFFECT_PREVIEW = "preview.png"

        private fun Array<String>.describesEffect() =
            contains(EFFECT_SCRIPT) || contains(EFFECT_SCENE)

        /// 빌드 때 적어 둔 "우리가 넣은 효과" 목록.
        private const val BUNDLED_LIST = "bnb-resources/bundled_effects.txt"
        private const val PREPARED_DIR = "banuba_effects"
    }

    /// 쓸 수 있는 효과 이름들. 자기를 설명하는 파일이 없는 폴더는 효과가
    /// 아니다(예전에 `images`·`meshes`처럼 공용 리소스만 든 폴더가 섞여 있었다).
    fun availableEffects(): List<String> = try {
        val ours = bundledNames()
        (context.assets.list(ASSET_ROOT) ?: emptyArray())
            .filter { name ->
                // SDK가 자기 AAR로 끼워 넣는 효과(BeautyBGEffects 등)는 우리
                // 마스크가 아니다. 에셋 경로가 같아 섞이므로 목록으로 가른다.
                (ours.isEmpty() || ours.contains(name)) &&
                    (context.assets.list("$ASSET_ROOT/$name") ?: emptyArray())
                        .describesEffect()
            }
            .sorted()
    } catch (failure: Exception) {
        Log.w(TAG, "cannot list effects: ${failure.javaClass.simpleName}")
        emptyList()
    }

    /// 빌드 때 적어 둔 목록. 없으면 빈 집합 — 그때는 거르지 않는다.
    private fun bundledNames(): Set<String> = try {
        context.assets.open(BUNDLED_LIST).bufferedReader().use { reader ->
            reader.readLines().map(String::trim).filter(String::isNotEmpty).toSet()
        }
    } catch (failure: Exception) {
        emptySet()
    }

    /// 카드에 깔 그림까지 붙인 목록.
    ///
    /// **왜 그림도 네이티브가 주나**: 예전에는 `preview.png`를 Flutter 에셋으로
    /// 선언해 썼다. 그러면 효과 폴더를 갈아 끼울 때마다 pubspec의 목록과 실제
    /// 파일이 어긋나 **빌드가 깨진다** — 실제로 그랬다. 효과 폴더는 이미
    /// 안드로이드 에셋으로 통째로 들어와 있으니, 그림 한 장만 꺼내 경로를 주면
    /// pubspec은 이 일에 관여할 필요가 없다.
    fun availableEffectCards(): List<Map<String, String?>> =
        availableEffects().map { name ->
            mapOf("name" to name, "previewPath" to preparePreview(name))
        }

    /// 미리보기 그림 한 장만 꺼낸다. 없으면 null — 카드가 기본 아이콘으로 그린다.
    private fun preparePreview(effectName: String): String? {
        val hasPreview = (context.assets.list("$ASSET_ROOT/$effectName") ?: emptyArray())
            .contains(EFFECT_PREVIEW)
        if (!hasPreview) return null
        val destination = File(
            File(context.filesDir, PREPARED_DIR),
            "$effectName-preview.png",
        )
        if (destination.isFile && destination.length() > 0) {
            return destination.absolutePath
        }
        return try {
            destination.parentFile?.mkdirs()
            context.assets.open("$ASSET_ROOT/$effectName/$EFFECT_PREVIEW").use { input ->
                destination.outputStream().use(input::copyTo)
            }
            destination.absolutePath
        } catch (failure: Exception) {
            Log.w(TAG, "no preview for '$effectName'")
            null
        }
    }

    /// 효과 하나를 펴고 그 폴더 Uri를 준다. 없는 효과면 null.
    fun prepareEffect(effectName: String): Uri? {
        if (effectName.isBlank() || !availableEffects().contains(effectName)) {
            return null
        }
        val destination = File(File(context.filesDir, PREPARED_DIR), effectName)
        // 이미 펴 뒀으면 다시 풀지 않는다. 효과 하나가 수 MB라 매번 풀면 마스크를
        // 고를 때마다 눈에 띄게 걸린다. 여기서도 두 파일을 다 본다 — 스크립트만
        // 찾으면 장면만 있는 효과는 매번 처음부터 다시 푼다.
        if (destination.list()?.describesEffect() == true) {
            return Uri.fromFile(destination)
        }
        return try {
            copyAssetTree("$ASSET_ROOT/$effectName", destination)
            Uri.fromFile(destination)
        } catch (failure: Exception) {
            Log.w(TAG, "cannot prepare '$effectName': ${failure.javaClass.simpleName}")
            destination.deleteRecursively()
            null
        }
    }

    private fun copyAssetTree(assetPath: String, destination: File) {
        val children = context.assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            destination.parentFile?.mkdirs()
            context.assets.open(assetPath).use { input ->
                destination.outputStream().use(input::copyTo)
            }
            return
        }
        destination.mkdirs()
        for (child in children) {
            copyAssetTree("$assetPath/$child", File(destination, child))
        }
    }
}
