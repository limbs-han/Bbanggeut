package com.wj.server.iot.auth;

import java.util.Optional;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

@Mapper
public interface DeviceCredentialMapper {

    @Select("""
        SELECT c.device_id, c.key_id, c.secret_hash, c.status, c.expires_at,
               d.status AS device_status, c.purpose
          FROM device_credentials c
          JOIN devices d ON d.id = c.device_id
         WHERE c.key_id = #{keyId}
           AND c.credential_type = 'TOKEN_HASH'
           AND c.status = 'ACTIVE'
           AND c.expires_at > now()
           AND d.status IN ('UNCLAIMED', 'ONLINE', 'OFFLINE')
        """)
    Optional<DeviceCredentialRow> findActiveToken(@Param("keyId") String keyId);
}
