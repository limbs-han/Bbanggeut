import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 지금 화면에 나오는 그림이 **실시간 맨 앞**인지.
enum LiveEdge {
  /// 재생 중이 아니라 따질 것이 없다.
  unknown,

  /// 맨 앞이다 — 빨간 불이 켜진다.
  live,

  /// 뒤처졌다 — 화면이 멈췄거나 지연이 커졌다. 빨간 불이 꺼진다.
  behind,
}

/// 실시간 여부를 판단할 때 쓰는 인바운드 영상 통계 한 조각.
class InboundVideoSample {
  const InboundVideoSample({required this.framesDecoded, this.bufferDelay});

  /// 지금까지 풀어낸 프레임 수(누적). 늘지 않으면 화면이 멈춘 것이다.
  final int framesDecoded;

  /// 프레임 한 장이 지터 버퍼에서 기다린 평균 시간. 통계를 주지 않는
  /// 기기도 있어 null일 수 있다.
  final Duration? bufferDelay;
}

/// Receives video and audio tracks from a WHEP endpoint.
///
/// Signaling is completed with a non-trickle SDP exchange so MediaMTX can be
/// used without a separate WebSocket signaling service.
class WhepPlayerController extends ChangeNotifier {
  WhepPlayerController({Dio? httpClient})
    : _httpClient =
          httpClient ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
            ),
          );

  final Dio _httpClient;
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  RTCPeerConnection? _peerConnection;
  Uri? _sessionUri;
  Future<void>? _closeFuture;
  bool _rendererInitialized = false;
  bool _disposed = false;
  bool _connected = false;
  bool _muted = false;

  bool get connected => _connected;

  /// 통계를 얼마나 자주 읽을지. WebRTC `getStats()`는 가벼운 호출이라 1초면
  /// 표시가 늦다는 느낌 없이 따라온다.
  static const liveEdgeSampleInterval = Duration(seconds: 1);

  /// 프레임 한 장이 이보다 오래 버퍼에서 기다리면 뒤처진 것으로 본다.
  ///
  /// WebRTC 라이브는 보통 50~250ms다. 망이 나빠지면 수신 쪽 지터 버퍼가
  /// 스스로 늘어나면서 지연이 쌓이는데, 그때가 "실시간이 아닌" 상태다.
  static const maxLiveEdgeDelay = Duration(milliseconds: 900);

  /// 새 프레임이 이만큼 안 오면 화면이 멈춘 것으로 본다. 멈춘 화면은
  /// 연결이 살아 있어도 실시간이 아니다.
  static const maxFrameStall = Duration(seconds: 2);

  LiveEdge _liveEdge = LiveEdge.unknown;
  Duration? _liveDelay;
  Timer? _liveEdgeTimer;
  int? _lastFramesDecoded;
  DateTime? _lastFrameAdvanceAt;

  /// 지금 실시간 맨 앞인가. 화면의 빨간 불이 이것을 그린다.
  LiveEdge get liveEdge => _liveEdge;

  /// 마지막으로 잰 지연. 통계를 못 읽는 기기에서는 null이다.
  Duration? get liveDelay => _liveDelay;

  /// 빨간 불을 켜도 되는 상태.
  bool get atLiveEdge => _connected && _liveEdge == LiveEdge.live;

  @visibleForTesting
  static const receiveMediaTypes = <RTCRtpMediaType>[
    RTCRtpMediaType.RTCRtpMediaTypeVideo,
    RTCRtpMediaType.RTCRtpMediaTypeAudio,
  ];

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (_rendererInitialized) {
      await renderer.setVolume(muted ? 0 : 1);
    }
  }

  Future<void> connect(String endpoint) async {
    if (_disposed) {
      throw StateError('WHEP player is already disposed');
    }
    await close();
    if (!_rendererInitialized) {
      await renderer.initialize();
      _rendererInitialized = true;
    }

    // WHEP playback is receive-only, so the plugin's default communication
    // profile is wrong for it. That profile puts Android in
    // MODE_IN_COMMUNICATION with USAGE_VOICE_COMMUNICATION, which routes
    // Bluetooth output over the SCO call channel instead of A2DP: audio breaks
    // up while video stays clean. It also engages the mic and ties playback to
    // the call volume stream. Media mode uses A2DP and the music stream.
    // No-op off Android.
    await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration.media);

    final endpointUri = Uri.parse(endpoint);
    final videoTrackReady = Completer<void>();
    final audioTrackReady = Completer<void>();
    final iceGatheringComplete = Completer<void>();
    final peer = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
    });
    _peerConnection = peer;

    peer.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !iceGatheringComplete.isCompleted) {
        iceGatheringComplete.complete();
      }
    };
    peer.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _connected = false;
        _stopLiveEdgeMonitor();
        notifyListeners();
        if (!videoTrackReady.isCompleted) {
          videoTrackReady.completeError(const WhepPlaybackException());
        }
        if (!audioTrackReady.isCompleted) {
          audioTrackReady.completeError(const WhepPlaybackException());
        }
      }
    };
    peer.onTrack = (event) {
      if (event.streams.isEmpty) return;
      renderer.srcObject = event.streams.first;
      if (event.track.kind == 'audio') {
        unawaited(renderer.setVolume(_muted ? 0 : 1));
        if (!audioTrackReady.isCompleted) audioTrackReady.complete();
        return;
      }
      if (event.track.kind != 'video') return;
      if (!videoTrackReady.isCompleted) videoTrackReady.complete();
    };

    for (final mediaType in receiveMediaTypes) {
      await peer.addTransceiver(
        kind: mediaType,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }

    try {
      final offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      if (peer.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await iceGatheringComplete.future.timeout(const Duration(seconds: 5));
      }
      final localDescription = await peer.getLocalDescription();
      final localSdp = localDescription?.sdp;
      if (localSdp == null || localSdp.isEmpty) {
        throw const WhepPlaybackException();
      }

      final response = await _httpClient.postUri<String>(
        endpointUri,
        data: localSdp,
        options: Options(
          contentType: 'application/sdp',
          responseType: ResponseType.plain,
          headers: const {'Accept': 'application/sdp'},
        ),
      );
      final answerSdp = response.data;
      if (answerSdp == null || answerSdp.isEmpty) {
        throw const WhepPlaybackException();
      }
      if (!hasActiveAudioMedia(answerSdp)) {
        // Production live playback requires MediaMTX to send WebRTC audio.
        throw const WhepPlaybackException();
      }

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        final resolved = endpointUri.resolve(location);
        _sessionUri = copyAccessQuery(resolved, endpointUri);
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      await Future.wait([
        videoTrackReady.future,
        audioTrackReady.future,
      ]).timeout(const Duration(seconds: 10));
      if (!await _waitForInboundAudio(peer)) {
        throw const WhepPlaybackException();
      }
      _connected = true;
      // 방금 붙었으면 정의상 맨 앞이다. unknown으로 두면 첫 통계가 올
      // 때까지 1초 동안 불이 꺼져 보인다.
      _liveEdge = LiveEdge.live;
      _startLiveEdgeMonitor();
      notifyListeners();
    } catch (_) {
      await close();
      throw const WhepPlaybackException();
    }
  }

  /// 인바운드 영상 통계에서 실시간 판단에 쓸 값만 추린다.
  @visibleForTesting
  static InboundVideoSample? readInboundVideo(Iterable<StatsReport> reports) {
    for (final report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final kind = report.values['kind'] ?? report.values['mediaType'];
      if (kind != 'video') continue;
      // jitterBufferDelay는 내보낸 프레임마다 더해진 **누적 초**다. 프레임
      // 수로 나눠야 한 장이 실제로 기다린 시간이 나온다.
      final emitted = _statNumber(report.values['jitterBufferEmittedCount']);
      final delay = _statNumber(report.values['jitterBufferDelay']);
      return InboundVideoSample(
        framesDecoded: _statNumber(report.values['framesDecoded']).toInt(),
        bufferDelay: emitted > 0
            ? Duration(microseconds: (delay / emitted * 1000000).round())
            : null,
      );
    }
    return null;
  }

  /// 지연과 정지 시간만 보고 실시간 여부를 정한다.
  @visibleForTesting
  static LiveEdge judgeLiveEdge({
    required Duration? bufferDelay,
    required Duration sinceLastNewFrame,
  }) {
    if (sinceLastNewFrame >= maxFrameStall) return LiveEdge.behind;
    if (bufferDelay != null && bufferDelay > maxLiveEdgeDelay) {
      return LiveEdge.behind;
    }
    return LiveEdge.live;
  }

  void _startLiveEdgeMonitor() {
    _liveEdgeTimer?.cancel();
    _lastFramesDecoded = null;
    _lastFrameAdvanceAt = DateTime.now();
    _liveEdgeTimer = Timer.periodic(
      liveEdgeSampleInterval,
      (_) => unawaited(_sampleLiveEdge()),
    );
  }

  void _stopLiveEdgeMonitor() {
    _liveEdgeTimer?.cancel();
    _liveEdgeTimer = null;
    _lastFramesDecoded = null;
    _lastFrameAdvanceAt = null;
    _liveEdge = LiveEdge.unknown;
    _liveDelay = null;
  }

  Future<void> _sampleLiveEdge() async {
    final peer = _peerConnection;
    if (peer == null || !_connected || _disposed) return;
    final InboundVideoSample? sample;
    try {
      sample = readInboundVideo(await peer.getStats());
    } catch (_) {
      // 통계를 못 읽는 것은 뒤처졌다는 증거가 아니다. 표시를 건드리지 않는다.
      return;
    }
    if (sample == null || _disposed || !_connected) return;

    final now = DateTime.now();
    final previous = _lastFramesDecoded;
    if (previous == null || sample.framesDecoded > previous) {
      _lastFrameAdvanceAt = now;
    }
    _lastFramesDecoded = sample.framesDecoded;
    _liveDelay = sample.bufferDelay;

    final next = judgeLiveEdge(
      bufferDelay: sample.bufferDelay,
      sinceLastNewFrame: now.difference(_lastFrameAdvanceAt ?? now),
    );
    // 알리는 것은 상태가 바뀔 때뿐이다. 매 초 알리면 라이브 화면 전체가
    // 초당 한 번씩 다시 그려진다.
    if (next == _liveEdge) return;
    _liveEdge = next;
    notifyListeners();
  }

  @visibleForTesting
  static Uri copyAccessQuery(Uri target, Uri source) {
    final query = <String, String>{...target.queryParameters};
    for (final key in const ['token', 'streamId']) {
      final value = source.queryParameters[key];
      if (value != null && value.isNotEmpty) query[key] = value;
    }
    return target.replace(queryParameters: query);
  }

  @visibleForTesting
  static bool hasActiveAudioMedia(String sdp) {
    final lines = sdp.split(RegExp(r'\r?\n'));
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (!line.startsWith('m=audio ')) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length <= 1 || parts[1] == '0') return false;

      var direction = 'sendrecv';
      for (
        var sectionIndex = index + 1;
        sectionIndex < lines.length && !lines[sectionIndex].startsWith('m=');
        sectionIndex++
      ) {
        final attribute = lines[sectionIndex].trim();
        if (attribute == 'a=sendonly' ||
            attribute == 'a=sendrecv' ||
            attribute == 'a=recvonly' ||
            attribute == 'a=inactive') {
          direction = attribute.substring(2);
        }
      }
      // This is the remote answer. Audio is playable only when MediaMTX
      // actually sends it. An unsupported publisher codec can leave a
      // non-zero audio m-line as inactive/recvonly.
      return direction == 'sendonly' || direction == 'sendrecv';
    }
    return false;
  }

  @visibleForTesting
  static bool hasInboundAudioPackets(Iterable<StatsReport> reports) {
    for (final report in reports) {
      if (report.type != 'inbound-rtp') continue;
      final kind = report.values['kind'] ?? report.values['mediaType'];
      if (kind != 'audio') continue;
      final packetsReceived = _statNumber(report.values['packetsReceived']);
      final bytesReceived = _statNumber(report.values['bytesReceived']);
      if (packetsReceived > 0 || bytesReceived > 0) return true;
    }
    return false;
  }

  static num _statNumber(Object? value) {
    if (value is num) return value;
    return num.tryParse('$value') ?? 0;
  }

  static Future<bool> _waitForInboundAudio(RTCPeerConnection peer) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (hasInboundAudioPackets(await peer.getStats())) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final operation = _closeInternal();
    _closeFuture = operation;
    return operation.whenComplete(() {
      if (identical(_closeFuture, operation)) _closeFuture = null;
    });
  }

  Future<void> _closeInternal() async {
    _stopLiveEdgeMonitor();
    final sessionUri = _sessionUri;
    _sessionUri = null;
    if (sessionUri != null) {
      try {
        await _httpClient.deleteUri<void>(
          sessionUri,
          options: Options(validateStatus: (status) => status != null),
        );
      } catch (_) {}
    }

    final peer = _peerConnection;
    _peerConnection = null;
    _connected = false;
    if (_rendererInitialized) renderer.srcObject = null;
    if (peer != null) {
      try {
        await peer.close();
      } catch (_) {}
      await peer.dispose();
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await close();
    if (_rendererInitialized) await renderer.dispose();
  }
}

class WhepPlaybackException implements Exception {
  const WhepPlaybackException();

  @override
  String toString() =>
      'WebRTC 영상과 오디오를 수신하지 못했습니다. 송출 장치의 Opus 오디오 설정을 확인해 주세요.';
}
