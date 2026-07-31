import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 큰 파일을 여러 연결로 나눠 받는다.
///
/// 휴대폰 회선에서는 TCP 연결 하나가 내는 처리량이 회선 용량보다 한참 낮다.
/// 같은 오브젝트를 Range 요청으로 쪼개 동시에 받으면 실측으로 두세 배 빨라진다.
/// MinIO/S3 presigned URL은 서명에 Range 헤더가 들어가지 않으므로 서명을 다시
/// 받을 필요도 없다.
///
/// Range를 무시하는 서버(200으로 전체를 주는 서버)나 병렬 수신이 막힌 회선에서는
/// 예전과 똑같은 한 줄 다운로드로 저절로 되돌아간다 — 빨라지지 않을 뿐 실패하지
/// 않는다.
class FastDownloader {
  const FastDownloader._();

  /// 첫 요청으로 받아 볼 크기.
  ///
  /// 이 응답의 Content-Range 하나로 전체 크기와 Range 지원 여부를 같이 알아낸다.
  /// HEAD를 따로 던지지 않으니 왕복 한 번을 아끼고, 서버가 Range를 무시해도
  /// 그 응답이 곧 파일 전체라 버릴 게 없다.
  static const _probeBytes = 1024 * 1024;

  /// 남은 구간을 나눠 받을 최대 연결 수. 더 늘려도 회선이 먼저 포화된다.
  static const _maxSegments = 8;

  /// 이보다 잘게 쪼개면 요청 왕복이 병렬 이득보다 커진다.
  static const _minSegmentBytes = 512 * 1024;

  /// 디스크에 한 번에 밀어 넣는 크기.
  ///
  /// 받은 덩어리(대개 64KiB)마다 곧바로 쓰면 구간 수만큼 쓰기가 줄을 서서
  /// 서로를 기다린다. 모아서 쓰면 시스템 콜이 8분의 1로 줄고 그 줄서기도
  /// 짧아진다.
  static const _writeBlockBytes = 512 * 1024;

  /// 진행률을 올려 보내는 최소 간격(ms).
  ///
  /// 덩어리마다 알리면 50MiB 영상에서 800번 넘게 화면을 다시 그린다. 그
  /// 리빌드가 다운로드와 **같은 isolate**에서 도므로 화면이 버벅일 뿐 아니라
  /// 받는 속도까지 갉아먹었다. 눈으로는 15Hz면 충분히 매끄럽다.
  static const _progressIntervalMs = 66;

  static Dio? _shared;

  /// 오브젝트 스토리지 전용 클라이언트.
  ///
  /// 앱 API 클라이언트와 분리해야 Bearer 인터셉터가 presigned URL에 붙지 않는다.
  /// 인스턴스를 살려 두면 연결 풀이 유지돼 저장·편집을 이어서 할 때 TLS
  /// 핸드셰이크를 다시 하지 않는다.
  static Dio get client => _shared ??= _buildClient();

  static Dio _buildClient() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        // 스트림에서는 "덩어리 사이 간격"이다. 전체 소요 시간이 아니다.
        receiveTimeout: const Duration(seconds: 60),
        headers: const {'Accept': 'video/*,application/octet-stream'},
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..maxConnectionsPerHost = _maxSegments + 3
        ..connectionTimeout = const Duration(seconds: 10)
        ..idleTimeout = const Duration(seconds: 30)
        // 영상은 이미 압축돼 있다. gzip을 요청하면 서버는 줄지도 않을 데이터를
        // 압축하느라 시간을 쓰고 우리는 그걸 도로 풀어야 한다.
        ..autoUncompress = false,
    );
    return dio;
  }

  static Future<void> download(
    String url,
    String destinationPath, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      await _segmented(url, destinationPath, onReceiveProgress, cancelToken);
      return;
    } on DioException catch (failure) {
      if (CancelToken.isCancel(failure)) rethrow;
      final statusCode = failure.response?.statusCode;
      // 서명이 만료됐다. 같은 URL로 몇 번을 더 받아도 결과가 같으니
      // 새 URL을 받아 올지는 호출부가 정하게 그대로 올려보낸다.
      if (statusCode == 401 || statusCode == 403) rethrow;
    } catch (_) {
      if (cancelToken?.isCancelled ?? false) rethrow;
    }
    // 병렬 수신이 어떤 이유로든 어긋났다. 예전 방식으로 한 번 더 받는다.
    await client.download(
      url,
      destinationPath,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
      deleteOnError: true,
    );
  }

  static Future<void> _segmented(
    String url,
    String destinationPath,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  ) async {
    final destination = File(destinationPath);
    await destination.parent.create(recursive: true);
    final handle = await destination.open(mode: FileMode.write);

    // 구간 하나가 실패하면 나머지도 같이 끊는다. 이 함수가 실패하면 통째로
    // 다시 받으므로, 남겨 두면 쓸모없어진 데이터를 계속 받게 된다.
    final segments = CancelToken();
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) => segments.cancel()));
    }

    // RandomAccessFile 하나에 여러 구간이 동시에 쓰면 위치가 엉킨다. 쓰기만
    // 줄을 세운다 — 병목은 회선이라 속도에는 영향이 없다.
    var writes = Future<void>.value();
    var received = 0;
    var total = 0;

    Future<void> writeAt(int offset, List<int> bytes) {
      final queued = writes.then((_) async {
        await handle.setPosition(offset);
        await handle.writeFrom(bytes);
      });
      // 앞선 쓰기가 실패해도 뒤 쓰기가 같은 오류로 두 번 터지지 않게 한다.
      // 실제 오류는 이 함수를 기다리는 쪽에서 그대로 받는다.
      writes = queued.catchError((Object _) {});
      return queued;
    }

    final clock = Stopwatch()..start();
    var reportedAtMs = -_progressIntervalMs;

    void report({bool force = false}) {
      if (onReceiveProgress == null) return;
      final nowMs = clock.elapsedMilliseconds;
      if (!force && nowMs - reportedAtMs < _progressIntervalMs) return;
      reportedAtMs = nowMs;
      onReceiveProgress(total > 0 ? math.min(received, total) : received, total);
    }

    Future<void> drain(Stream<List<int>> stream, int offset) async {
      // 받는 족족 쓰지 않고 블록만큼 모아서 쓴다.
      final pending = BytesBuilder(copy: false);
      var blockStart = offset;
      await for (final chunk in stream) {
        pending.add(chunk);
        received += chunk.length;
        report();
        if (pending.length >= _writeBlockBytes) {
          final block = pending.takeBytes();
          await writeAt(blockStart, block);
          blockStart += block.length;
        }
      }
      if (pending.isNotEmpty) {
        await writeAt(blockStart, pending.takeBytes());
      }
    }

    try {
      final probe = await client.get<ResponseBody>(
        url,
        cancelToken: segments,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${_probeBytes - 1}'},
        ),
      );
      final body = probe.data;
      if (body == null) {
        throw DioException(
          requestOptions: probe.requestOptions,
          message: 'The download response had no body.',
        );
      }

      final rangeTotal = _totalBytes(probe.headers.value('content-range'));
      if (probe.statusCode != 206) {
        // 서버가 Range를 무시했다. 이 응답이 곧 파일 전체다.
        total =
            int.tryParse(
              probe.headers.value(Headers.contentLengthHeader) ?? '',
            ) ??
            0;
        await drain(body.stream, 0);
        await writes;
        report(force: true);
        return;
      }
      if (rangeTotal == null) {
        // 일부만 보냈다면서 전체 크기를 알려주지 않았다. 이 응답만 저장하면
        // 잘린 파일이 남는다 — 통째로 받는 쪽으로 넘긴다.
        throw DioException(
          requestOptions: probe.requestOptions,
          message: 'A partial response arrived without a usable Content-Range.',
        );
      }

      total = rangeTotal;

      // 첫 실패가 진짜 이유다. 그 뒤 취소로 줄줄이 생기는 오류는 덮어쓰지
      // 않는다. Future.wait은 기본적으로 전부 끝나기를 기다리므로, 실패한
      // 순간 나머지를 끊어야 통째로 다시 받는 쪽으로 빨리 넘어간다.
      Object? failure;
      Future<void> guarded(Future<void> task) => task.catchError((Object error) {
        failure ??= error;
        if (!segments.isCancelled) segments.cancel();
      });

      final tasks = <Future<void>>[guarded(drain(body.stream, 0))];
      for (final range in _remainingRanges(
        math.min(_probeBytes, total),
        total,
      )) {
        tasks.add(guarded(_fetchRange(url, range, drain, segments)));
      }
      await Future.wait(tasks);
      await writes;
      if (failure != null) throw failure!;
      report(force: true);

      final written = await handle.length();
      if (written != total) {
        throw DioException(
          requestOptions: RequestOptions(path: url),
          message: 'Received $written of $total bytes.',
        );
      }
    } finally {
      // 성공했다면 모든 요청이 이미 끝나 아무 일도 일어나지 않는다. 실패했다면
      // 아직 받고 있던 구간들의 연결이 여기서 닫힌다.
      if (!segments.isCancelled) segments.cancel();
      await handle.close();
    }
  }

  static Future<void> _fetchRange(
    String url,
    _ByteRange range,
    Future<void> Function(Stream<List<int>> stream, int offset) drain,
    CancelToken? cancelToken,
  ) async {
    DioException? lastFailure;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await client.get<ResponseBody>(
          url,
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=${range.start}-${range.end}'},
          ),
        );
        final body = response.data;
        if (body == null) {
          throw DioException(
            requestOptions: response.requestOptions,
            message: 'The range response had no body.',
          );
        }
        await drain(body.stream, range.start);
        return;
      } on DioException catch (failure) {
        if (CancelToken.isCancel(failure)) rethrow;
        final statusCode = failure.response?.statusCode;
        if (statusCode == 401 || statusCode == 403) rethrow;
        lastFailure = failure;
      }
    }
    throw lastFailure!;
  }

  /// 첫 조각 뒤에 남은 구간을 연결 수만큼 고르게 자른다.
  static List<_ByteRange> _remainingRanges(int from, int total) {
    final remaining = total - from;
    if (remaining <= 0) return const [];
    final count = math.min(
      _maxSegments,
      math.max(1, remaining ~/ _minSegmentBytes),
    );
    final size = (remaining / count).ceil();
    final ranges = <_ByteRange>[];
    for (var start = from; start < total; start += size) {
      ranges.add(_ByteRange(start, math.min(start + size, total) - 1));
    }
    return ranges;
  }

  /// `bytes 0-1048575/52428800` 에서 전체 크기만 떼어 낸다.
  static int? _totalBytes(String? contentRange) {
    if (contentRange == null) return null;
    final separator = contentRange.lastIndexOf('/');
    if (separator < 0) return null;
    return int.tryParse(contentRange.substring(separator + 1).trim());
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}
