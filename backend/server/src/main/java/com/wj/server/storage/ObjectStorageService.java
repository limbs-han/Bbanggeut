package com.wj.server.storage;

import java.time.Clock;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.nio.file.Path;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.StorageProperties;
import io.minio.GetPresignedObjectUrlArgs;
import io.minio.Http;
import io.minio.ListObjectsArgs;
import io.minio.MinioClient;
import io.minio.RemoveObjectsArgs;
import io.minio.Result;
import io.minio.StatObjectArgs;
import io.minio.StatObjectResponse;
import io.minio.RemoveObjectArgs;
import io.minio.GetObjectArgs;
import io.minio.UploadObjectArgs;
import io.minio.messages.DeleteRequest;
import io.minio.messages.DeleteResult;
import io.minio.messages.Item;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;

@Service
public class ObjectStorageService {
    private final MinioClient minioClient;
    private final MinioClient presignClient;
    private final StorageProperties properties;
    private final Clock clock;

    @Autowired
    public ObjectStorageService(MinioClient minioClient, StorageProperties properties) {
        this(minioClient, properties, Clock.systemUTC());
    }

    ObjectStorageService(MinioClient minioClient, StorageProperties properties, Clock clock) {
        this.minioClient = minioClient;
        this.presignClient = MinioClient.builder()
            .endpoint(properties.publicEndpoint())
            .credentials(properties.accessKey(), properties.secretKey())
            .build();
        this.properties = properties;
        this.clock = clock;
    }

    /**
     * 편집 완성본 업로드용 서명 URL. 기기 업로드와 달리 Content-Type만
     * 서명한다 — 올리는 주체가 OS 백그라운드 작업(WorkManager)이라 세션도
     * 없고 추가 헤더를 붙일 수도 없다. 무결성은 도착 후 크기로 확인한다.
     */
    public PresignedUpload createEditUploadUrl(String storageKey, String contentType) {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", contentType);
        try {
            String url = presignClient.getPresignedObjectUrl(GetPresignedObjectUrlArgs.builder()
                .method(Http.Method.PUT)
                .bucket(properties.bucket())
                .object(storageKey)
                .expiry(Math.toIntExact(properties.uploadUrlTtl().toSeconds()), TimeUnit.SECONDS)
                .extraHeaders(headers)
                .build());
            return new PresignedUpload(
                url, headers, Instant.now().plus(properties.uploadUrlTtl()));
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    public PresignedUpload createUploadUrl(String storageKey, String contentType, String checksumSha256) {
        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Content-Type", contentType);
        headers.put("x-amz-meta-sha256", checksumSha256);
        try {
            String url = presignClient.getPresignedObjectUrl(GetPresignedObjectUrlArgs.builder()
                .method(Http.Method.PUT)
                .bucket(properties.bucket())
                .object(storageKey)
                .expiry(Math.toIntExact(properties.uploadUrlTtl().toSeconds()), TimeUnit.SECONDS)
                .extraHeaders(headers)
                .build());
            return new PresignedUpload(
                url, Map.copyOf(headers), clock.instant().plus(properties.uploadUrlTtl()));
        } catch (Exception exception) {
            throw new ApiException(
                HttpStatus.SERVICE_UNAVAILABLE,
                "OBJECT_STORAGE_UNAVAILABLE",
                "객체 저장소를 사용할 수 없습니다.");
        }
    }

    public StoredObject stat(String storageKey) {
        try {
            StatObjectResponse stat = minioClient.statObject(StatObjectArgs.builder()
                .bucket(properties.bucket())
                .object(storageKey)
                .build());
            return new StoredObject(
                stat.size(), stat.userMetadata().getFirst("sha256"), stat.etag());
        } catch (io.minio.errors.ErrorResponseException exception) {
            if ("NoSuchKey".equals(exception.errorResponse().code())
                || "NoSuchObject".equals(exception.errorResponse().code())) {
                throw new ApiException(
                    HttpStatus.CONFLICT, "UPLOAD_OBJECT_NOT_FOUND", "업로드된 객체를 찾을 수 없습니다.");
            }
            throw unavailable();
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    public SignedObjectUrl createReadUrl(String storageKey, boolean download) {
        try {
            GetPresignedObjectUrlArgs.Builder builder = GetPresignedObjectUrlArgs.builder()
                .method(Http.Method.GET)
                .bucket(properties.bucket())
                .object(storageKey)
                .expiry(Math.toIntExact(properties.readUrlTtl().toSeconds()), TimeUnit.SECONDS);
            if (download) {
                builder.extraQueryParams(Map.of("response-content-disposition", "attachment"));
            }
            String url = presignClient.getPresignedObjectUrl(builder.build());
            return new SignedObjectUrl(url, clock.instant().plus(properties.readUrlTtl()));
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    public void remove(String storageKey) {
        try {
            minioClient.removeObject(RemoveObjectArgs.builder()
                .bucket(properties.bucket())
                .object(storageKey)
                .build());
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    /** 편집 서버(editor-api)가 이 영상에 대해 만든 부산물의 버킷 내 위치. */
    private static final String[] EDIT_DATA_PREFIXES =
        {"edit-analyses/", "edit-projects/", "edited-videos/", "thumbnails/"};

    /**
     * 목록용 미리보기 그림의 편집 버킷 내 위치. editor-api가 같은 규칙으로
     * 쓴다({@code video_editor/service.py}의 {@code _thumbnail_key}) — 규칙이
     * 어긋나면 그림은 만들어지는데 아무도 못 읽는다.
     *
     * <p>파일을 바로 두지 않고 디렉터리를 한 겹 두는 이유는 {@link
     * #EDIT_DATA_PREFIXES} 기반 삭제에 걸리게 하기 위해서다.
     */
    public static String thumbnailKey(UUID videoId) {
        return "thumbnails/" + videoId + "/frame.jpg";
    }

    /**
     * 미리보기 그림을 받을 단기 URL. 편집 버킷이 설정돼 있지 않으면 null이다.
     *
     * <p><b>있는지 확인하지 않는다.</b> 서명은 네트워크 없이 계산만 하는 일이라
     * 목록 스무 건에 스무 번 해도 공짜지만, 존재 확인은 건마다 MinIO 왕복이라
     * 목록 응답이 그만큼 느려진다. 아직 그림이 없는 영상의 URL은 404가 되고,
     * 앱은 그때 예전처럼 기기에서 프레임을 뽑는다 — 느려질 뿐 깨지지 않는다.
     */
    public String createThumbnailReadUrl(UUID videoId) {
        String bucket = properties.editBucket();
        if (bucket == null || bucket.isBlank()) {
            return null;
        }
        try {
            return presignClient.getPresignedObjectUrl(GetPresignedObjectUrlArgs.builder()
                .method(Http.Method.GET)
                .bucket(bucket)
                .object(thumbnailKey(videoId))
                .expiry(Math.toIntExact(properties.readUrlTtl().toSeconds()), TimeUnit.SECONDS)
                .build());
        } catch (Exception exception) {
            // 목록을 통째로 못 그리게 만들 값이 아니다. 없으면 앱이 예전 경로로 간다.
            return null;
        }
    }

    /**
     * 원본이 삭제된 영상의 편집 부산물(분석 캐시·초안·편집본·댓글)을 편집
     * 버킷에서 지운다. 편집 버킷이 설정돼 있지 않으면 아무것도 하지 않고,
     * 지울 것이 없어도 성공한다 — 삭제 워커가 재시도해도 안전하다.
     */
    public void removeEditData(String videoId) {
        String bucket = properties.editBucket();
        if (bucket == null || bucket.isBlank()) {
            return;
        }
        for (String prefix : EDIT_DATA_PREFIXES) {
            removePrefix(bucket, prefix + videoId + "/");
        }
    }

    private void removePrefix(String bucket, String prefix) {
        try {
            List<DeleteRequest.Object> targets = new ArrayList<>();
            for (Result<Item> item : minioClient.listObjects(ListObjectsArgs.builder()
                .bucket(bucket)
                .prefix(prefix)
                .recursive(true)
                .build())) {
                targets.add(new DeleteRequest.Object(item.get().objectName()));
            }
            if (targets.isEmpty()) {
                return;
            }
            // removeObjects는 게으르다 — 결과를 끝까지 소비해야 실제로 지워진다.
            for (Result<DeleteResult.Error> result : minioClient.removeObjects(
                RemoveObjectsArgs.builder().bucket(bucket).objects(targets).build())) {
                DeleteResult.Error error = result.get();
                throw new IllegalStateException(
                    "편집 데이터 삭제 실패: " + error.objectName() + " — " + error.message());
            }
        } catch (io.minio.errors.ErrorResponseException exception) {
            if ("NoSuchBucket".equals(exception.errorResponse().code())) {
                // 편집 버킷이 아직 없다 = 지울 부산물도 없다. 삭제를 막지 않는다.
                return;
            }
            throw unavailable();
        } catch (ApiException | IllegalStateException exception) {
            throw exception;
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    public void download(String storageKey, Path destination) {
        try (var input = minioClient.getObject(GetObjectArgs.builder()
            .bucket(properties.bucket())
            .object(storageKey)
            .build())) {
            java.nio.file.Files.copy(input, destination, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    public void upload(String storageKey, Path source, String contentType, String checksumSha256) {
        try {
            minioClient.uploadObject(UploadObjectArgs.builder()
                .bucket(properties.bucket())
                .object(storageKey)
                .filename(source.toString())
                .contentType(contentType)
                .userMetadata(Map.of("sha256", checksumSha256))
                .build());
        } catch (Exception exception) {
            throw unavailable();
        }
    }

    private ApiException unavailable() {
        return new ApiException(
            HttpStatus.SERVICE_UNAVAILABLE,
            "OBJECT_STORAGE_UNAVAILABLE",
            "객체 저장소를 사용할 수 없습니다.");
    }

    public record PresignedUpload(String url, Map<String, String> requiredHeaders, Instant expiresAt) {
    }

    public record StoredObject(long size, String checksumSha256, String etag) {
    }

    public record SignedObjectUrl(String url, Instant expiresAt) {
    }
}
