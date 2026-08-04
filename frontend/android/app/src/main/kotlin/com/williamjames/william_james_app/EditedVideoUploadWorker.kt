package com.williamjames.william_james_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * 렌더링된 편집 영상을 서버(editor-api)에 올리는 백그라운드 작업.
 *
 * 업로드는 셀룰러에서 몇 분씩 걸리는데 사용자는 앱에 오래 머물지 않는다 —
 * 예전에는 업로드가 끝날 때까지 편집기에 붙잡아 뒀고, 기다리다 앱을 꺼서
 * 업로드가 끊긴 일도 있었다. WorkManager에 맡기면 앱을 나가거나 프로세스가
 * 죽어도 OS가 이어서 돌리고, 회선이 끊기면 다시 붙을 때 재시도한다.
 * 진행률은 상단 알림으로 보인다.
 */
class EditedVideoUploadWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    companion object {
        private const val TAG = "WjEditUpload"

        const val KEY_FILE_PATH = "filePath"
        const val KEY_UPLOAD_URL = "uploadUrl"
        const val KEY_TITLE = "title"

        /// 렌더링 산출물(임시 파일)이면 올린 뒤 지운다. 원본을 그대로 올리는
        /// 경우(다시 그릴 것이 없는 편집)는 캐시 파일이라 지우면 안 된다 —
        /// 다음 편집 진입이 도로 내려받게 된다.
        const val KEY_DELETE_AFTER = "deleteAfter"

        private const val CHANNEL_ID = "edited-video-upload"
        private const val PROGRESS_NOTIFICATION_ID = 20401
        private const val RESULT_NOTIFICATION_ID = 20402
        private const val MAX_ATTEMPTS = 5
    }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val filePath = inputData.getString(KEY_FILE_PATH)
        val uploadUrl = inputData.getString(KEY_UPLOAD_URL)
        val title = inputData.getString(KEY_TITLE).orEmpty().ifBlank { "편집 영상" }
        if (filePath.isNullOrBlank() || uploadUrl.isNullOrBlank()) {
            Log.w(TAG, "업로드 입력이 비어 있다 filePath=$filePath uploadUrl=${uploadUrl != null}")
            return@withContext Result.failure()
        }
        val file = File(filePath)
        if (!file.isFile || file.length() == 0L) {
            // 재시도하던 사이에 파일이 지워졌다 — 다시 시도해도 소용없다.
            Log.w(TAG, "올릴 파일이 없다 path=$filePath exists=${file.exists()} size=${file.length()}")
            notifyResult(title, success = false, reason = "만들어진 영상 파일을 찾지 못했어요")
            return@withContext Result.failure()
        }
        // 진행률 알림은 있으면 좋은 것이다. 안드로이드 12부터 백그라운드에서
        // 포그라운드 서비스를 띄우는 것이 제한되므로(편집기를 닫고 화면을 끄면
        // 바로 걸린다), 승격이 실패해도 업로드는 그대로 진행한다 — 예전에는
        // 이 한 줄이 던지면서 업로드를 시작조차 못 하고 실패 알림만 떴다.
        try {
            setForeground(foregroundInfo(title, percent = 0))
        } catch (failure: Exception) {
            Log.w(TAG, "진행률 알림을 띄우지 못해 조용히 올린다: ${failure.javaClass.simpleName}")
        }
        try {
            upload(file, uploadUrl, title)
            if (inputData.getBoolean(KEY_DELETE_AFTER, false)) file.delete()
            notifyResult(title, success = true)
            Result.success()
        } catch (failure: RecoverableUploadFailure) {
            val attempt = runAttemptCount + 1
            Log.w(TAG, "업로드 일시 실패 attempt=$attempt/$MAX_ATTEMPTS: ${failure.message}")
            if (attempt >= MAX_ATTEMPTS) {
                notifyResult(
                    title,
                    success = false,
                    reason = "$MAX_ATTEMPTS 번 시도했지만 연결이 이어지지 않았어요",
                )
                Result.failure()
            } else {
                Result.retry()
            }
        } catch (failure: Exception) {
            Log.w(TAG, "업로드 실패: ${failure.javaClass.simpleName}: ${failure.message}", failure)
            notifyResult(title, success = false, reason = failure.message)
            Result.failure()
        }
    }

    /// 회선 문제·서버 일시 장애처럼 나중에 다시 하면 될 수 있는 실패.
    private class RecoverableUploadFailure(message: String) : Exception(message)

    private fun upload(file: File, uploadUrl: String, title: String) {
        val connection = URL(uploadUrl).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "PUT"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "video/mp4")
            connection.connectTimeout = 30_000
            connection.readTimeout = 120_000
            // 길이를 미리 알려 스트리밍 전송한다 — 파일을 메모리에 다 안 든다.
            connection.setFixedLengthStreamingMode(file.length())
            val total = file.length()
            var sent = 0L
            var lastShownPercent = 0
            try {
                file.inputStream().use { input ->
                    connection.outputStream.use { output ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            sent += read
                            val percent = (sent * 100 / total).toInt()
                            if (percent >= lastShownPercent + 5) {
                                lastShownPercent = percent
                                // 진행률 표시가 막혀도 업로드는 계속한다.
                                try {
                                    setForegroundAsync(foregroundInfo(title, percent))
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                }
                val code = connection.responseCode
                when {
                    code in 200..299 -> Unit
                    // 서버 일시 장애·타임아웃·과부하는 재시도 가치가 있다.
                    code >= 500 || code == 408 || code == 429 ->
                        throw RecoverableUploadFailure("server $code")
                    // 거절 이유는 본문에 있다(MinIO는 XML로 Code를 준다). 이걸
                    // 버리면 실패 알림만 남아 원인을 알 길이 없다.
                    else -> throw IllegalStateException(
                        "upload rejected: $code ${errorBody(connection)}")
                }
            } catch (failure: IOException) {
                throw RecoverableUploadFailure(failure.message ?: "io failure")
            }
        } finally {
            connection.disconnect()
        }
    }

    /** 거절 응답의 앞부분. 원인(MinIO의 XML Code 등)만 짧게 남긴다. */
    private fun errorBody(connection: HttpURLConnection): String =
        try {
            connection.errorStream?.bufferedReader()?.use { it.readText() }
                ?.take(300)
                ?.replace(Regex("\\s+"), " ")
                .orEmpty()
        } catch (_: Exception) {
            ""
        }

    private fun notificationManager(): NotificationManager {
        val manager = applicationContext
            .getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "편집 영상 업로드",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        return manager
    }

    private fun foregroundInfo(title: String, percent: Int): ForegroundInfo {
        notificationManager()
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("편집 영상을 서버에 올리는 중")
            .setContentText(title)
            .setProgress(100, percent, percent == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(
                PROGRESS_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(PROGRESS_NOTIFICATION_ID, notification)
        }
    }

    /**
     * 결과 알림. 실패하면 [reason]을 함께 보여 준다 — 예전에는 제목만 있어서
     * 사용자도 개발자도 무엇이 잘못됐는지 알 수 없었다. 자세한 내용은
     * `adb logcat -s $TAG`에 남는다.
     */
    private fun notifyResult(title: String, success: Boolean, reason: String? = null) {
        val detail = reason?.takeIf { it.isNotBlank() }
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(
                if (success) {
                    android.R.drawable.stat_sys_upload_done
                } else {
                    android.R.drawable.stat_notify_error
                },
            )
            .setContentTitle(if (success) "편집 영상을 저장했어요" else "편집 영상 업로드에 실패했어요")
            .setContentText(
                if (success) {
                    "추억 > 편집 완료에서 볼 수 있어요 · $title"
                } else {
                    detail?.let { "$title — $it" } ?: title
                },
            )
            .apply {
                if (!success && detail != null) {
                    setStyle(NotificationCompat.BigTextStyle().bigText("$title\n$detail"))
                }
            }
            .setAutoCancel(true)
            .build()
        notificationManager().notify(RESULT_NOTIFICATION_ID, notification)
    }
}
