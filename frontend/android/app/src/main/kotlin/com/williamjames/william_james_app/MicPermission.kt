package com.williamjames.william_james_app

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * RECORD_AUDIO 런타임 권한을 묻는다.
 *
 * **왜 필요한가**: ML Kit 음성 인식은 **파일을 주는데도** 이 권한을 요구한다.
 * 없으면 ERROR_TYPE_INSUFFICIENT_PERMISSION으로 죽는다. 매니페스트 선언만으로는
 * 안 되고 사용자에게 물어야 한다.
 *
 * 지금까지는 라이브 보기(WebRTC)가 켜질 때 얻어걸린 권한에 기대고 있었다. 라이브를
 * 한 번도 안 켠 사용자는 자막 생성에서 그대로 실패한다 — whisper 폴백이 가려 주고
 * 있었을 뿐이다.
 *
 * **패키지를 새로 넣지 않고 직접 부른다.** 권한 하나 때문에 의존성을 늘릴 이유가 없다.
 */
object MicPermission {
    private const val REQUEST_CODE = 0xB1C

    /** 요청 결과를 기다리는 쪽. 동시에 두 번 묻지 않는다. */
    private var pending: ((Boolean) -> Unit)? = null

    fun isGranted(activity: Activity) =
        ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * 이미 있으면 즉시 true. 없으면 물어보고 답이 오면 [onResult]를 부른다.
     *
     * 사용자가 "다시 묻지 않음"을 골랐다면 대화상자가 뜨지 않고 바로 거부로 온다.
     * 그때는 호출부가 설정으로 안내해야 한다.
     */
    fun ensure(activity: Activity, onResult: (Boolean) -> Unit) {
        if (isGranted(activity)) {
            onResult(true)
            return
        }
        if (pending != null) {
            // 이미 대화상자가 떠 있다. 두 번 물으면 앞의 요청이 답을 못 받는다.
            onResult(false)
            return
        }
        pending = onResult
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQUEST_CODE,
        )
    }

    /** [MainActivity.onRequestPermissionsResult]가 그대로 넘겨준다. */
    fun handleResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending?.invoke(granted)
        pending = null
        return true
    }
}
