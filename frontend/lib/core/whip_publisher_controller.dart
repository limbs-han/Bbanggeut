import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Sends microphone audio to a WHIP endpoint so it plays on the device speaker.
///
/// Signaling mirrors [WhepPlayerController]: a non-trickle SDP exchange that
/// MediaMTX accepts without a separate WebSocket signaling service.
class WhipPublisherController extends ChangeNotifier {
  WhipPublisherController({Dio? httpClient})
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

  RTCPeerConnection? _peerConnection;
  MediaStream? _microphone;
  Uri? _sessionUri;
  Future<void>? _closeFuture;
  bool _disposed = false;
  bool _transmitting = false;

  bool get transmitting => _transmitting;

  Future<void> connect(String endpoint) async {
    if (_disposed) {
      throw StateError('WHIP publisher is already disposed');
    }
    await close();

    // Talkback is the one path that needs the microphone, so it needs the
    // communication profile that WhepPlayerController deliberately avoids.
    // The caller restores the media profile when transmission ends; leaving
    // the device in communication mode would route Bluetooth playback over
    // SCO and degrade ordinary live viewing.
    await Helper.setAndroidAudioConfiguration(
      AndroidAudioConfiguration.communication,
    );

    // flutter_webrtc가 Android 런타임 권한 요청을 직접 띄운다. 거부는 재시도로
    // 풀리지 않으므로 전송 실패와 구분해서 알린다.
    try {
      _microphone = await navigator.mediaDevices.getUserMedia(const {
        'audio': true,
        'video': false,
      });
    } catch (_) {
      await close();
      throw const MicrophonePermissionException();
    }

    final endpointUri = Uri.parse(endpoint);
    final iceGatheringComplete = Completer<void>();
    RTCPeerConnection? peer;
    try {
      peer = await createPeerConnection({
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
            state ==
                RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _transmitting = false;
          notifyListeners();
        }
      };

      for (final track in _microphone!.getAudioTracks()) {
        await peer.addTrack(track, _microphone!);
      }

      final offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      if (peer.iceGatheringState !=
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        await iceGatheringComplete.future.timeout(const Duration(seconds: 5));
      }
      final localDescription = await peer.getLocalDescription();
      final localSdp = localDescription?.sdp;
      if (localSdp == null || localSdp.isEmpty) {
        throw const WhipPublishException();
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
        throw const WhipPublishException();
      }
      if (!acceptsAudio(answerSdp)) {
        throw const WhipPublishException();
      }

      final location = response.headers.value('location');
      if (location != null && location.isNotEmpty) {
        final resolved = endpointUri.resolve(location);
        _sessionUri = copyAccessQuery(resolved, endpointUri);
      }

      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      _transmitting = true;
      notifyListeners();
    } catch (_) {
      await close();
      throw const WhipPublishException();
    }
  }

  /// The talkback lease is short and refreshed by the viewer heartbeat. Nothing
  /// here renews it; the caller stops transmitting when the lease is lost.
  @visibleForTesting
  static Uri copyAccessQuery(Uri target, Uri source) {
    final query = <String, String>{...target.queryParameters};
    for (final key in const ['token', 'streamId']) {
      final value = source.queryParameters[key];
      if (value != null && value.isNotEmpty) query[key] = value;
    }
    return target.replace(queryParameters: query);
  }

  /// MediaMTX answers a WHIP offer with `recvonly` audio when it accepts the
  /// publisher. A zero port or an inactive direction means the audio never
  /// reaches the device, so transmitting would be silently useless.
  @visibleForTesting
  static bool acceptsAudio(String sdp) {
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
      return direction == 'recvonly' || direction == 'sendrecv';
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
    _transmitting = false;
    if (peer != null) {
      try {
        await peer.close();
      } catch (_) {}
      await peer.dispose();
    }

    // Release the microphone before restoring the media profile. A live track
    // keeps Android in communication mode and the recording indicator on.
    final microphone = _microphone;
    _microphone = null;
    if (microphone != null) {
      for (final track in microphone.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
      try {
        await microphone.dispose();
      } catch (_) {}
    }
    try {
      await Helper.setAndroidAudioConfiguration(
        AndroidAudioConfiguration.media,
      );
    } catch (_) {}

    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}

class WhipPublishException implements Exception {
  const WhipPublishException();

  @override
  String toString() => '마이크 오디오를 기기로 전송하지 못했습니다. 잠시 후 다시 시도해 주세요.';
}

class MicrophonePermissionException implements Exception {
  const MicrophonePermissionException();

  @override
  String toString() => '말하기를 사용하려면 마이크 권한을 허용해 주세요.';
}
