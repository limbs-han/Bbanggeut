package com.wj.server.iot.telemetry;

import java.time.Instant;
import java.util.UUID;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface DeviceTelemetryMapper {
    @Update("""
        UPDATE devices
           SET status = CASE WHEN claimed_at IS NOT NULL THEN 'ONLINE'::device_status ELSE status END,
               last_seen_at = now(), recording = #{recording},
               upload_queue_depth = #{uploadQueueDepth}, buffer_seconds = #{bufferSeconds},
               firmware_version = COALESCE(#{firmwareVersion}, firmware_version), updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED'
        """)
    int recordHeartbeat(
        @Param("deviceId") UUID deviceId,
        @Param("recording") boolean recording,
        @Param("uploadQueueDepth") int uploadQueueDepth,
        @Param("bufferSeconds") Integer bufferSeconds,
        @Param("firmwareVersion") String firmwareVersion
    );

    @Update("""
        UPDATE devices
           SET registration_mode_expires_at = #{expiresAt}, updated_at = now()
         WHERE id = #{deviceId} AND status = 'UNCLAIMED'
        """)
    int updateRegistrationMode(@Param("deviceId") UUID deviceId, @Param("expiresAt") Instant expiresAt);

    @Update("""
        UPDATE devices
           SET status = CASE
                 WHEN #{online} AND claimed_at IS NOT NULL THEN 'ONLINE'::device_status
                 WHEN NOT #{online} AND claimed_at IS NOT NULL THEN 'OFFLINE'::device_status
                 ELSE status
               END,
               last_seen_at = CASE WHEN #{online} THEN now() ELSE last_seen_at END,
               recording = CASE WHEN #{online} THEN recording ELSE false END,
               firmware_version = COALESCE(#{firmwareVersion}, firmware_version), updated_at = now()
         WHERE id = #{deviceId} AND status != 'REVOKED'
        """)
    int recordConnectionState(
        @Param("deviceId") UUID deviceId,
        @Param("online") boolean online,
        @Param("firmwareVersion") String firmwareVersion
    );
}
