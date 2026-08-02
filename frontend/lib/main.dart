import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'core/push_notification_service.dart';

/// Puts WebRTC playback on the media volume stream before anything starts it.
///
/// `Helper.setAndroidAudioConfiguration` in WhepPlayerController only reaches
/// the routing/focus manager. The audio attributes of the device module that
/// actually plays the remote track can only be set while that module is built,
/// which happens on the plugin's first call. Left alone the module defaults to
/// USAGE_VOICE_COMMUNICATION and is scaled by STREAM_VOICE_CALL, so live audio
/// arrives at earpiece-calibrated gain through the loudspeaker and the volume
/// keys — which move STREAM_MUSIC — cannot turn it up. That was the drop heard
/// after live playback moved from HLS to WHEP: the old video_player path ran on
/// STREAM_MUSIC. The same preset is used here and in the controller so the
/// focus request and the playback stream cannot disagree.
Future<void> _configureWebRtcAudioForMediaPlayback() async {
  if (kIsWeb) {
    return;
  }
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await WebRTC.initialize(
        options: <String, dynamic>{
          'androidAudioConfiguration': AndroidAudioConfiguration.media.toMap(),
        },
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await AppleNativeAudioManagement.setAppleAudioConfiguration(
        AppleNativeAudioManagement.getAppleAudioConfigurationForMode(
          AppleAudioIOMode.remoteOnly,
        ),
      );
    }
  } catch (error, stackTrace) {
    // Quiet live audio is worth reporting, not worth blocking startup over.
    debugPrint('WebRTC audio configuration failed: $error\n$stackTrace');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _configureWebRtcAudioForMediaPlayback();
  await PushNotificationService.shared.bootstrap();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFFF8F8F2),
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  await initializeDateFormatting('ko');
  runApp(const WilliamJamesApp());
}
