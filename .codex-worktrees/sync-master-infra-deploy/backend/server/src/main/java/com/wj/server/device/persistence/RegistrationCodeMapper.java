package com.wj.server.device.persistence;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.device.domain.RegistrationCodeRow;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface RegistrationCodeMapper {

    /**
     * Refreshes the physical registration window. Returns 0 when the device is
     * not UNCLAIMED, which callers must treat as "code issuance refused".
     */
    @Update("""
        UPDATE devices
           SET registration_mode_expires_at = #{expiresAt}, updated_at = now()
         WHERE id = #{deviceId} AND status = 'UNCLAIMED'
        """)
    int refreshRegistrationMode(@Param("deviceId") UUID deviceId, @Param("expiresAt") Instant expiresAt);

    /** Re-entering registration mode always invalidates earlier unused codes. */
    @Delete("""
        DELETE FROM registration_codes
         WHERE device_id = #{deviceId} AND used_at IS NULL
        """)
    int deleteUnusedCodes(@Param("deviceId") UUID deviceId);

    /**
     * Collision pre-check. A duplicate insert would abort the surrounding
     * transaction in PostgreSQL, so the generator checks before inserting.
     */
    @Select("""
        SELECT EXISTS (SELECT 1 FROM registration_codes WHERE code_hash = #{codeHash})
        """)
    boolean hashExists(@Param("codeHash") String codeHash);

    @Insert("""
        INSERT INTO registration_codes (device_id, code_hash, expires_at)
        VALUES (#{deviceId}, #{codeHash}, #{expiresAt})
        """)
    int insertCode(
        @Param("deviceId") UUID deviceId,
        @Param("codeHash") String codeHash,
        @Param("expiresAt") Instant expiresAt
    );

    @Select("""
        SELECT rc.id, rc.device_id, rc.expires_at, rc.used_at,
               d.status AS device_status
          FROM registration_codes rc
          JOIN devices d ON d.id = rc.device_id
         WHERE rc.code_hash = #{codeHash}
         FOR UPDATE OF rc, d
        """)
    Optional<RegistrationCodeRow> findByHashForUpdate(@Param("codeHash") String codeHash);

    @Update("""
        UPDATE registration_codes
           SET used_at = now(), used_by = #{userId}
         WHERE id = #{codeId} AND used_at IS NULL AND expires_at > now()
        """)
    int markUsed(@Param("codeId") UUID codeId, @Param("userId") UUID userId);
}
