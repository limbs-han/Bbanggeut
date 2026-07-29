import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Receives a single video track from a WHEP endpoint.
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

  bool get connected => _connected;

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
    final trackReady = Completer<void>();
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
        if (!trackReady.isCompleted) {
          trackReady.completeError(const WhepPlaybackException());
        }
      }
    };
    peer.onTrack = (event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) return;
      renderer.srcObject = event.streams.first;
      _connected = true;
      notifyListeners();
      if (!trackReady.isCompleted) trackReady.complete();
    };

    await peer.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

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

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        final resolved = endpointUri.resolve(location);
        _sessionUri = copyAccessQuery(resolved, endpointUri);
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      await trackReady.future.timeout(const Duration(seconds: 10));
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
