package com.williamjames.william_james_app

import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.text.SpannableString
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * "AR + AI 자막이면 내보내기가 video frame processor error로 죽는다"의 회귀
 * 테스트.
 *
 * media3의 OverlayShaderProgram은 오버레이 15개까지만 받는다 — 예전 구조는
 * 자막 한 줄당 오버레이 하나라 AI 자막 몇십 줄 + AR 스티커에서 그 한계를
 * 넘겼다. 지금은 시간이 겹치지 않는 레이어들이 레인 하나(오버레이 하나)를
 * 나눠 쓴다(EditorLayerOverlay 참조). 여기서는 그 레인 배치와, 실제 media3
 * 파이프라인 통과 여부를 함께 확인한다.
 */
@UnstableApi
@RunWith(AndroidJUnit4::class)
class EditorOverlayExportTest {
    /** AI 자막처럼 시간이 이어지는(겹치지 않는) 자막 [count]줄. */
    private fun captionLayers(count: Int): List<Map<String, Any?>> =
        (0 until count).map { index ->
            mapOf(
                "text" to "자막 $index",
                "startMs" to index * 60,
                "endMs" to index * 60 + 50,
                "position" to mapOf("x" to 0.5, "y" to 0.78),
                "fontSize" to 28,
                "bold" to true,
            )
        }

    /** AR '파티' 효과가 놓는 것과 같은, 전 구간에 겹쳐 있는 스티커 3장. */
    private fun arStickerLayers(endMs: Int): List<Map<String, Any?>> =
        listOf("🎉", "🥳", "🎈").map { emoji ->
            mapOf(
                "value" to emoji,
                "startMs" to 0,
                "endMs" to endMs,
                "position" to mapOf("x" to 0.5, "y" to 0.2),
                "scale" to 1.2,
            )
        }

    @Test
    fun laneCountIsConcurrencyNotLayerCount() {
        val overlays = EditorLayerOverlay.from(
            captionLayers(30),
            arStickerLayers(endMs = 2000),
            1f,
        )
        // 자막 30줄은 서로 겹치지 않아 레인 1개, 스티커 3장은 전 구간이
        // 겹쳐 레인 3개. media3 한계(15)에 한참 못 미친다.
        assertEquals(4, overlays.size)
    }

    @Test
    fun exportSurvivesManyCaptionsWithArStickers() {
        val failure = runExport(
            EditorLayerOverlay.from(captionLayers(30), arStickerLayers(2000), 1f),
        )
        assertNull("내보내기가 실패했다: ${chain(failure)}", failure)
    }

    /** 원인 체인을 한 줄로 — "Asset loader error" 한 줄로는 진단이 안 된다. */
    private fun chain(failure: Throwable?): String =
        generateSequence(failure) { it.cause }
            .joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }

    /**
     * 예전 구조(레이어당 오버레이 하나)가 정확히 이 입력에서 죽는다는 증거.
     * 이 테스트가 실패하기 시작하면 media3가 한계를 올렸다는 뜻이므로
     * 레인 배치를 단순화할 수 있는지 다시 판단하면 된다.
     */
    @Test
    fun overlayPerLayerReproducesFrameProcessorError() {
        val perLayer = (0 until 30).map<Int, TextureOverlay> { index ->
            TextOverlay.createStaticTextOverlay(SpannableString("자막 $index"))
        }
        val failure = runExport(perLayer)
        assertNotNull("오버레이 30개가 통과했다 — media3 한계가 바뀌었는지 확인", failure)
        assertTrue(
            "죽은 이유가 오버레이 한계가 아니다: ${chain(failure)}",
            chain(failure).contains("overlays"),
        )
    }

    /**
     * [overlays]를 얹어 2초짜리 단색 프레임 영상을 실제로 인코딩한다.
     * 성공하면 null, 실패하면 그 예외를 준다.
     */
    private fun runExport(overlays: List<TextureOverlay>): ExportException? {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val image = File(context.cacheDir, "overlay-test-frame.png")
        if (!image.isFile) {
            val bitmap = Bitmap.createBitmap(640, 360, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(Color.rgb(30, 90, 160))
            image.outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
        val output = File(context.cacheDir, "overlay-test-${System.nanoTime()}.mp4")
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.fromFile(image))
            // 이미지 입력의 길이는 MediaItem 쪽에 지정해야 한다 — 없으면
            // "asset loader has no audio or video track"으로 죽는다.
            .setImageDurationMs(2_000)
            .build()
        val item = EditedMediaItem.Builder(mediaItem)
            .setFrameRate(30)
            .build()
        val effects = mutableListOf<Effect>(
            Presentation.createForWidthAndHeight(
                1280,
                720,
                Presentation.LAYOUT_SCALE_TO_FIT,
            ),
        )
        if (overlays.isNotEmpty()) effects += OverlayEffect(overlays)
        val composition =
            Composition.Builder(EditedMediaItemSequence.withVideoFrom(listOf(item)))
                .setEffects(Effects(emptyList(), effects))
                .build()
        var failure: ExportException? = null
        val done = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            Transformer.Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .addListener(
                    object : Transformer.Listener {
                        override fun onCompleted(
                            composition: Composition,
                            exportResult: ExportResult,
                        ) {
                            done.countDown()
                        }

                        override fun onError(
                            composition: Composition,
                            exportResult: ExportResult,
                            exportException: ExportException,
                        ) {
                            failure = exportException
                            done.countDown()
                        }
                    },
                )
                .build()
                .start(composition, output.absolutePath)
        }
        assertTrue("내보내기가 2분 안에 끝나지 않았다", done.await(120, TimeUnit.SECONDS))
        if (failure == null) {
            assertTrue("출력 파일이 비었다", output.isFile && output.length() > 0)
        }
        output.delete()
        return failure
    }
}
