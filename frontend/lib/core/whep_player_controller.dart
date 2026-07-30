import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
      _connected = true;
      notifyListeners();
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
        // MediaMTX does not transcode AAC to a WebRTC audio codec. Falling
        // back to HLS preserves sound when the publisher is AAC-only.
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
    } catch (_) {
      await close();
      throw const WhepPlaybackException();
    }
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
    for (final line in sdp.split(RegExp(r'\r?\n'))) {
      if (!line.startsWith('m=audio ')) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      return parts.length > 1 && parts[1] != '0';
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
  String toString() => 'WebRTC 라이브 연결에 실패했습니다.';
}
