package com.wj.server.storage;

import java.time.Clock;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.nio.file.Path;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.StorageProperties;
import io.minio.GetPresignedObjectUrlArgs;
import io.minio.Http;
import io.minio.MinioClient;
import io.minio.StatObjectArgs;
import io.minio.StatObjectResponse;
import io.minio.RemoveObjectArgs;
import io.minio.GetObjectArgs;
import io.minio.UploadObjectArgs;
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
