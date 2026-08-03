package com.williamjames.william_james_app

/// Flutter와 주고받는 이름들. Dart 쪽 `banuba_mask_channel.dart`와 **짝**이다.
///
/// 양쪽에 문자열을 흩어 놓으면 한쪽만 고쳐도 컴파일은 되고 런타임에만 조용히
/// 어긋난다. 한 곳에 모아 두고 여기만 보고 맞춘다.
internal object BanubaMaskContract {
    const val METHOD_CHANNEL = "com.williamjames/banuba_mask"
    const val EVENT_CHANNEL = "com.williamjames/banuba_mask_events"
    const val VIEW_TYPE = "com.williamjames/banuba_mask_preview"

    // 메서드
    const val INITIALIZE = "initialize"
    const val SET_VIDEO_SOURCE = "setVideoSource"
    const val PLAY = "play"
    const val PAUSE = "pause"
    const val SEEK_TO = "seekTo"
    const val APPLY_MASK = "applyMask"
    const val REMOVE_MASK = "removeMask"
    const val AVAILABLE_MASKS = "availableMasks"
    const val EXPORT = "export"
    const val CANCEL_EXPORT = "cancelExport"
    const val DISPOSE = "dispose"

    // 인자
    const val ARG_TOKEN = "token"
    const val ARG_VIDEO_PATH = "videoPath"
    const val ARG_START_MS = "startMs"
    const val ARG_END_MS = "endMs"
    const val ARG_POSITION_MS = "positionMs"
    const val ARG_MASK_NAME = "maskName"
    const val ARG_OUTPUT_PATH = "outputPath"
    const val ARG_WIDTH = "width"
    const val ARG_HEIGHT = "height"
    const val ARG_DURATION_MS = "durationMs"
    const val ARG_VOLUME = "volume"

    /// 저장할 구간들. `startMs`/`endMs`를 담은 지도의 목록이고, **순서대로**
    /// 이어 붙여 한 편으로 굽는다. 컷 편집에서 나눠 둔 조각이 그대로 온다.
    const val ARG_RANGES = "ranges"

    // 이벤트(EventChannel로 올려 보내는 지도의 `type`)
    const val EVENT_TYPE = "type"
    const val EVENT_POSITION = "position"
    const val EVENT_STATE = "state"
    const val EVENT_MASK = "mask"
    const val EVENT_EXPORT_PROGRESS = "exportProgress"
    const val EVENT_ERROR = "error"

    // 상태값
    const val STATE_PREPARING = "preparing"
    const val STATE_READY = "ready"
    const val STATE_PLAYING = "playing"
    const val STATE_PAUSED = "paused"
    const val STATE_COMPLETED = "completed"

    // 오류 코드
    const val ERR_NO_TOKEN = "BANUBA_NO_TOKEN"
    const val ERR_INIT = "BANUBA_INIT_FAILED"
    const val ERR_NO_PREVIEW = "BANUBA_NO_PREVIEW"
    const val ERR_EFFECT_MISSING = "BANUBA_EFFECT_MISSING"
    const val ERR_EXPORT = "BANUBA_EXPORT_FAILED"
    const val ERR_EXPORT_CANCELLED = "BANUBA_EXPORT_CANCELLED"
}
