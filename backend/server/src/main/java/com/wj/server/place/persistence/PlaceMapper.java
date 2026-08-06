package com.wj.server.place.persistence;

import java.util.List;
import java.util.UUID;

import com.wj.server.place.domain.DevicePlaceRow;
import com.wj.server.place.domain.PlaceRow;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * 금고의 장소 배치(공통)와 기기 순서(사람마다).
 *
 * <p>둘 다 목록을 통째로 갈아 끼우는 방식이다. 앱이 한 화면에서 여러 개를 한꺼번에
 * 바꾸고(장소 추가 + 기기 이동 + 순서 변경), 항목마다 API를 나누면 중간 상태가
 * 서버에 남는다.
 */
@Mapper
public interface PlaceMapper {
    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM vault_memberships m
             WHERE m.vault_id = #{vaultId} AND m.user_id = #{userId}
               AND m.status = 'ACTIVE'
        )
        """)
    boolean isActiveMember(@Param("userId") UUID userId, @Param("vaultId") UUID vaultId);

    @Select("""
        SELECT name, sort_order AS sortOrder FROM vault_places
         WHERE vault_id = #{vaultId}
         ORDER BY sort_order, name
        """)
    List<PlaceRow> findPlaces(@Param("vaultId") UUID vaultId);

    @Delete("DELETE FROM vault_places WHERE vault_id = #{vaultId}")
    int deletePlaces(@Param("vaultId") UUID vaultId);

    @Insert("""
        INSERT INTO vault_places (vault_id, name, sort_order)
        VALUES (#{vaultId}, #{name}, #{sortOrder})
        """)
    int insertPlace(
        @Param("vaultId") UUID vaultId,
        @Param("name") String name,
        @Param("sortOrder") int sortOrder
    );

    @Select("""
        SELECT device_id AS deviceId, place_name AS placeName
          FROM vault_device_places
         WHERE vault_id = #{vaultId}
        """)
    List<DevicePlaceRow> findDevicePlaces(@Param("vaultId") UUID vaultId);

    @Delete("DELETE FROM vault_device_places WHERE vault_id = #{vaultId}")
    int deleteDevicePlaces(@Param("vaultId") UUID vaultId);

    /**
     * 이 금고에 실제로 묶여 있는 기기만 배정한다.
     *
     * <p>금고에 없는 기기 id를 보내도 조용히 버려진다 — 앱이 목록을 통째로
     * 보내므로 방금 해제된 기기가 섞여 올 수 있고, 그걸 이유로 저장 전체를
     * 실패시키면 사용자는 왜 안 되는지 알 수 없다.
     */
    @Insert("""
        INSERT INTO vault_device_places (vault_id, device_id, place_name)
        SELECT #{vaultId}, #{deviceId}, #{placeName}
         WHERE EXISTS (
           SELECT 1 FROM device_bindings b
            WHERE b.vault_id = #{vaultId} AND b.device_id = #{deviceId}
              AND b.ended_at IS NULL
         )
        """)
    int insertDevicePlace(
        @Param("vaultId") UUID vaultId,
        @Param("deviceId") UUID deviceId,
        @Param("placeName") String placeName
    );

    @Select("""
        SELECT device_id FROM user_device_orders
         WHERE user_id = #{userId} AND vault_id = #{vaultId}
         ORDER BY sort_order
        """)
    List<UUID> findDeviceOrder(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Delete("""
        DELETE FROM user_device_orders
         WHERE user_id = #{userId} AND vault_id = #{vaultId}
        """)
    int deleteDeviceOrder(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId
    );

    @Insert("""
        INSERT INTO user_device_orders (user_id, vault_id, device_id, sort_order)
        SELECT #{userId}, #{vaultId}, #{deviceId}, #{sortOrder}
         WHERE EXISTS (
           SELECT 1 FROM device_bindings b
            WHERE b.vault_id = #{vaultId} AND b.device_id = #{deviceId}
              AND b.ended_at IS NULL
         )
        """)
    int insertDeviceOrder(
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("deviceId") UUID deviceId,
        @Param("sortOrder") int sortOrder
    );
}
