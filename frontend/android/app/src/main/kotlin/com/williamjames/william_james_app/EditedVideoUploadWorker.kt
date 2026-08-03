package com.williamjames.william_james_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
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
            return@withContext Result.failure()
        }
        val file = File(filePath)
        if (!file.isFile || file.length() == 0L) {
            // 재시도하던 사이에 파일이 지워졌다 — 다시 시도해도 소용없다.
            notifyResult(title, success = false)
            return@withContext Result.failure()
        }
        setForeground(foregroundInfo(title, percent = 0))
        try {
            upload(file, uploadUrl, title)
            if (inputData.getBoolean(KEY_DELETE_AFTER, false)) file.delete()
            notifyResult(title, success = true)
            Result.success()
        } catch (failure: RecoverableUploadFailure) {
            if (runAttemptCount + 1 >= MAX_ATTEMPTS) {
                notifyResult(title, success = false)
                Result.failure()
            } else {
                Result.retry()
            }
        } catch (failure: Exception) {
            notifyResult(title, success = false)
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
                                setForegroundAsync(foregroundInfo(title, percent))
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
                    else -> throw IllegalStateException("upload rejected: $code")
                }
            } catch (failure: IOException) {
                throw RecoverableUploadFailure(failure.message ?: "io failure")
            }
        } finally {
            connection.disconnect()
        }
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

    private fun notifyResult(title: String, success: Boolean) {
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
                if (success) "추억 > 편집 완료에서 볼 수 있어요 · $title" else title,
            )
            .setAutoCancel(true)
            .build()
        notificationManager().notify(RESULT_NOTIFICATION_ID, notification)
    }
}
