package com.williamjames.william_james_app

import android.app.Application
import android.util.Log
import com.banuba.sdk.core.license.BanubaLicenseManager
import com.banuba.sdk.core.license.EditorSdk
import com.banuba.sdk.export.data.ExportErrorParser
import com.banuba.sdk.export.data.ExportParamsProvider
import com.banuba.sdk.export.di.VeExportKoinModule
import com.banuba.sdk.export.internal.CoverContainsInExport
import com.banuba.sdk.playback.di.VePlaybackSdkKoinModule
import com.banuba.sdk.ve.di.VeSdkKoinModule
import org.koin.android.ext.koin.androidContext
import org.koin.core.context.GlobalContext
import org.koin.core.context.loadKoinModules
import org.koin.core.context.startKoin
import org.koin.core.module.Module
import org.koin.dsl.module

/// Banuba를 **프로세스에 한 번만** 세운다.
///
/// **왜 이 클래스가 따로 있나**: `ve_sdk_flutter` 플러그인도 같은 일을 하지만
/// (`VideoEditorModule.initialize`), 그 함수는 `internal`이라 앱 모듈에서 부를 수
/// 없고, 애초에 전체 편집기 화면을 열 때만 불린다. 우리는 편집기를 열지 않고
/// 미리보기만 쓰므로 같은 그래프를 여기서 세운다.
///
/// **편집기는 우리 것이고 Banuba는 엔진일 뿐이다.** Banuba 편집기 화면으로
/// 넘어가지 않으므로 그 화면용 모듈은 세우지 않는다.
/// [EditorSdk.initialize]도 한 번만 부른다.
internal object BanubaMaskRuntime {
    private const val TAG = "BanubaMask"

    /// 라이선스 확인까지 끝난 상태. 화면이 닫혀도 유지한다 — 화면 종료와 SDK
    /// 종료는 다른 일이다. 여기서 SDK를 내리면 다음 진입이 깨진다.
    @Volatile
    private var ready = false

    @Volatile
    private var koinLoaded = false

    /// 저장할 때 어디에 무슨 이름으로 구울지 [BanubaMaskExporter]가 여기에
    /// 넣어 둔다. Koin에는 이 인스턴스 하나만 물린다 — 내보내기 한가운데서
    /// 새 객체가 만들어지면 방금 넣은 요청이 사라진다.
    val exportParams = BanubaMaskExportParamsProvider()

    /// 준비되면 null, 아니면 실패 이유.
    @Synchronized
    fun ensureReady(application: Application, token: String): RuntimeFailure? {
        if (ready) return null
        if (token.isBlank()) {
            return RuntimeFailure(BanubaMaskContract.ERR_NO_TOKEN, "라이선스 토큰이 없어요.")
        }

        val initialized = try {
            EditorSdk.initialize(token)
        } catch (failure: Throwable) {
            Log.e(TAG, "SDK init threw", failure)
            null
        }
        if (initialized == null) {
            return RuntimeFailure(
                BanubaMaskContract.ERR_INIT,
                "Banuba 토큰을 인식하지 못했어요. Video Editor용 토큰인지 확인해 주세요.",
            )
        }

        val moduleFailure = loadModules(application)
        if (moduleFailure != null) return moduleFailure
        logLicenseLimits()
        ready = true
        return null
    }

    /// 라이선스가 **무엇을 허용하는지** 한 줄로 남긴다. 토큰 자체는 절대 찍지 않는다.
    ///
    /// **왜 필요한가**: 마스크가 한 명에게만 붙는 이유가 두 가지일 수 있다 —
    /// 라이선스가 얼굴 하나만 허용하거나(정책), 아니면 SDK의 영상 경로가
    /// 그 값을 안 쓰거나(구현). 앞은 우리가 어쩔 수 없고 뒤는 우회할 여지가
    /// 있는데, 겉으로 보이는 증상이 같아서 이 숫자 없이는 가릴 수 없다.
    ///
    /// 참고: 카메라 경로는 이 값을 `EffectPlayer.setMaxFaces`에 넣지만,
    /// 영상 경로(`BanubaClassFactory.createOfflineVideoEffectPlayer`)는 같은
    /// 인자를 받고도 쓰지 않는다 — 우리가 쓰는 쪽이 그 영상 경로다.
    /// `license` 속성은 Kotlin에서 private이라(바이트코드의 getter만 public이다)
    /// 리플렉션으로 읽는다. 진단용 한 줄이라 실패해도 그냥 넘어간다.
    private fun logLicenseLimits() = try {
        val license = BanubaLicenseManager::class.java
            .getMethod("getLicense")
            .invoke(BanubaLicenseManager)
        fun value(getter: String): Any? = try {
            license?.javaClass?.getMethod(getter)?.invoke(license)
        } catch (ignored: Throwable) {
            null
        }
        Log.d(
            TAG,
            "license: maxFaces=${value("getMaxFaces")} " +
                "faceAR=${value("getSupportsFaceAR")} " +
                "faceARonlyForPhotoEditor=${value("getFaceARonlyForPhotoEditor")} " +
                "veSdk=${value("getSupportsVeSdk")} " +
                "exportApi=${value("getSupportsExportApi")}",
        )
    } catch (failure: Throwable) {
        Log.w(TAG, "cannot read license limits: ${failure.javaClass.simpleName}")
    }

    /// 공식 모듈만 얹는다.
    ///
    /// 재생에 필요한 것은 셋이다 — `VeSdkKoinModule`(공통·DurationHelper),
    /// `VePlaybackSdkKoinModule`(VideoPlayerProvider), 그리고 얼굴 추적을 물어다
    /// 주는 `BanubaEffectPlayerKoinModule`(IMaskRendererFactory). 저장까지 하려면
    /// `VeExportKoinModule`이 더 필요하다.
    ///
    /// 효과 플레이어 모듈은 플러그인이 하는 것과 같은 이유로 **리플렉션**으로
    /// 얹는다: Face AR이 꺼진 빌드에서는 이 클래스가 아예 없어서, 직접 참조하면
    /// 링크 단계에서 터진다.
    ///
    /// **그래프의 주인은 우리다.**
    ///
    /// 편집기는 우리 것(Flutter + media3)이고 Banuba는 AR 탭이 빌려 쓰는 엔진일
    /// 뿐이다. Banuba 편집기 화면으로 넘어가는 길은 없앤다. 그래서 플러그인의
    /// 부트스트랩(`VideoCreationActivity`용 `VeFlow`·`VeUi` 등)은 애초에 돌 일이
    /// 없고, 우리는 재생과 저장에 필요한 것만 세운다.
    ///
    /// 다만 순서는 양쪽 다 견디게 둔다. 먼저 켠 쪽이 그래프를 독점하는 구조라
    /// (`startKoin`은 이미 켜져 있으면 던진다), 남이 켜 뒀으면 얹기만 한다.
    private fun loadModules(application: Application): RuntimeFailure? {
        if (koinLoaded) return null
        val modules = mutableListOf<Module>(
            VeSdkKoinModule().module,
            VeExportKoinModule().module,
            VePlaybackSdkKoinModule().module,
        )
        effectPlayerModule()?.let(modules::add)
        // 우리 것은 맨 뒤다. 뒤에 얹은 정의가 이긴다(allowOverride).
        modules.add(ourModule())
        try {
            if (GlobalContext.getOrNull() == null) {
                Log.d(TAG, "starting koin with ${modules.size} modules (we own it)")
                startKoin {
                    androidContext(application)
                    allowOverride(true)
                    modules(modules)
                }
            } else {
                Log.d(TAG, "koin already running, loading ${modules.size} modules")
                loadKoinModules(modules)
            }
        } catch (failure: Throwable) {
            Log.e(TAG, "koin setup failed", failure)
            return RuntimeFailure(
                BanubaMaskContract.ERR_INIT,
                "AR 엔진을 준비하지 못했어요.",
            )
        }
        koinLoaded = true
        return null
    }

    /// 공식 모듈이 못 채우는 자리만 우리가 메운다.
    ///
    /// - `CoverContainsInExport`: 원래 편집기 화면 모듈만 내놓는다. 우리는 그
    ///   화면으로 가지 않으니 "표지는 없다"로 답한다.
    /// - `ExportParamsProvider`: 기본값은 SDK가 정한 폴더·이름·해상도로 굽는다.
    ///   구운 파일을 곧바로 media3에 넘겨야 해서 우리가 정해야 한다.
    /// - `ExportErrorParser`: 분류는 기본 구현 그대로 두고 지나가는 예외만
    ///   우리 로그에 찍는다. 실패 이유가 enum 하나로 뭉쳐 오기 때문이다.
    ///
    /// 왜 여기 있나 — [BanubaMaskExportParamsProvider],
    /// [BanubaMaskCoverNotInExport], [BanubaMaskExportErrorParser] 설명에
    /// 이유가 적혀 있다.
    private fun ourModule(): Module = module {
        single<CoverContainsInExport> { BanubaMaskCoverNotInExport }
        single<ExportErrorParser> { BanubaMaskExportErrorParser }
        factory<ExportParamsProvider> { exportParams }
    }

    private fun effectPlayerModule(): Module? = try {
        val instance = Class
            .forName("com.banuba.sdk.effectplayer.adapter.BanubaEffectPlayerKoinModule")
            .getDeclaredConstructor()
            .newInstance()
        instance.javaClass
            .getDeclaredField("module")
            .apply { isAccessible = true }
            .get(instance) as? Module
    } catch (failure: Throwable) {
        Log.w(TAG, "Face AR module unavailable: ${failure.javaClass.simpleName}")
        null
    }

    data class RuntimeFailure(val code: String, val message: String)
}
