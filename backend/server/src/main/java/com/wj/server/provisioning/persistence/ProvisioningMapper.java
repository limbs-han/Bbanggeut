package com.wj.server.provisioning.persistence;

import java.util.Optional;
import java.util.UUID;

import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface ProvisioningMapper {

    @Select("""
        INSERT INTO devices (serial_number, name, model, firmware_version, status)
        VALUES (#{serialNumber}, #{name}, #{model}, #{firmwareVersion}, 'UNCLAIMED')
        RETURNING id
        """)
    UUID insertDevice(
        @Param("serialNumber") String serialNumber,
        @Param("name") String name,
        @Param("model") String model,
        @Param("firmwareVersion") String firmwareVersion
    );

    @Select("SELECT status::text FROM devices WHERE id = #{deviceId}")
    Optional<String> findDeviceStatus(@Param("deviceId") UUID deviceId);

    @Update("""
        UPDATE device_credentials
           SET status = 'REVOKED', revoked_at = now()
         WHERE device_id = #{deviceId} AND status = 'ACTIVE'
        """)
    int revokeActiveCredentials(@Param("deviceId") UUID deviceId);

    @Insert("""
        INSERT INTO device_credentials (
            device_id, key_id, credential_type, secret_hash, status
        ) VALUES (
            #{deviceId}, #{keyId}, 'TOKEN_HASH', #{secretHash}, 'ACTIVE'
        )
        """)
    int insertTokenCredential(
        @Param("deviceId") UUID deviceId,
        @Param("keyId") String keyId,
        @Param("secretHash") String secretHash
    );
}
