package com.wj.server.schedule.persistence;

import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.schedule.domain.ScheduleRow;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

/**
 * 금고 공유 일정. {@code vault_id}가 공유 범위이고 {@code user_id}는 작성자다.
 *
 * <p>수정·삭제 권한(작성자 또는 금고 OWNER)은 조건을 SQL에 함께 걸어 판정과
 * 변경을 한 문장으로 처리한다 — 먼저 읽어 검사한 뒤 쓰면 그 사이에 권한이
 * 회수될 수 있다.
 */
@Mapper
public interface ScheduleMapper {
    /**
     * 이 사용자가 볼 수 있는 일정.
     *
     * <p>금고가 없던 시절에 적은 일정({@code vault_id IS NULL})은 작성자에게만
     * 보인다 — 마이그레이션이 옮길 금고가 없던 일정이라 개인 일정으로 남는다.
     */
    @Select("""
        SELECT s.id, s.user_id AS userId, s.vault_id AS vaultId,
               u.display_name AS authorName,
               s.title, s.schedule_date AS scheduleDate, s.memo, s.yearly, s.emoji
          FROM user_schedules s
          JOIN users u ON u.id = s.user_id
         WHERE (
                 s.vault_id IN (
                   SELECT m.vault_id FROM vault_memberships m
                    WHERE m.user_id = #{userId} AND m.status = 'ACTIVE'
                 )
                 OR (s.vault_id IS NULL AND s.user_id = #{userId})
               )
         ORDER BY s.schedule_date, s.created_at, s.id
        """)
    List<ScheduleRow> findVisible(@Param("userId") UUID userId);

    /** 상한은 금고 기준이다 — 공유 목록이니까. 금고가 없으면 작성자 기준. */
    @Select("""
        SELECT count(*) FROM user_schedules
         WHERE (#{vaultId} IS NULL AND vault_id IS NULL AND user_id = #{userId})
            OR (#{vaultId} IS NOT NULL AND vault_id = #{vaultId})
        """)
    long countInScope(@Param("userId") UUID userId, @Param("vaultId") UUID vaultId);

    /** 이 사용자가 활성 구성원인 금고. 여러 곳이면 OWNER인 금고를 먼저 준다. */
    @Select("""
        SELECT m.vault_id FROM vault_memberships m
         WHERE m.user_id = #{userId} AND m.status = 'ACTIVE'
         ORDER BY CASE WHEN m.role = 'OWNER' THEN 0 ELSE 1 END, m.joined_at, m.vault_id
        """)
    List<UUID> findActiveVaultIds(@Param("userId") UUID userId);

    /** 남의 금고에 일정을 넣지 못하게 한다. */
    @Select("""
        SELECT EXISTS (
            SELECT 1 FROM vault_memberships m
             WHERE m.vault_id = #{vaultId} AND m.user_id = #{userId}
               AND m.status = 'ACTIVE'
        )
        """)
    boolean isActiveMember(@Param("userId") UUID userId, @Param("vaultId") UUID vaultId);

    @Insert("""
        INSERT INTO user_schedules
               (id, user_id, vault_id, title, schedule_date, memo, yearly, emoji)
        VALUES (#{id}, #{userId}, #{vaultId}, #{title}, #{scheduleDate},
                #{memo}, #{yearly}, #{emoji})
        """)
    int insert(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("vaultId") UUID vaultId,
        @Param("title") String title,
        @Param("scheduleDate") LocalDate scheduleDate,
        @Param("memo") String memo,
        @Param("yearly") boolean yearly,
        @Param("emoji") String emoji
    );

    @Select("""
        SELECT s.id, s.user_id AS userId, s.vault_id AS vaultId,
               u.display_name AS authorName,
               s.title, s.schedule_date AS scheduleDate, s.memo, s.yearly, s.emoji
          FROM user_schedules s
          JOIN users u ON u.id = s.user_id
         WHERE s.id = #{id}
        """)
    Optional<ScheduleRow> findById(@Param("id") UUID id);

    /** 작성자 또는 금고 OWNER만 통과한다. */
    @Update("""
        UPDATE user_schedules s
           SET title = #{title},
               schedule_date = #{scheduleDate},
               memo = #{memo},
               yearly = #{yearly},
               emoji = #{emoji},
               updated_at = now()
         WHERE s.id = #{id}
           AND (
                 s.user_id = #{userId}
                 OR EXISTS (
                   SELECT 1 FROM vault_memberships m
                    WHERE m.vault_id = s.vault_id AND m.user_id = #{userId}
                      AND m.role = 'OWNER' AND m.status = 'ACTIVE'
                 )
               )
        """)
    int update(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("title") String title,
        @Param("scheduleDate") LocalDate scheduleDate,
        @Param("memo") String memo,
        @Param("yearly") boolean yearly,
        @Param("emoji") String emoji
    );

    /** 작성자 또는 금고 OWNER만 통과한다. */
    @Delete("""
        DELETE FROM user_schedules s
         WHERE s.id = #{id}
           AND (
                 s.user_id = #{userId}
                 OR EXISTS (
                   SELECT 1 FROM vault_memberships m
                    WHERE m.vault_id = s.vault_id AND m.user_id = #{userId}
                      AND m.role = 'OWNER' AND m.status = 'ACTIVE'
                 )
               )
        """)
    int delete(@Param("id") UUID id, @Param("userId") UUID userId);
}
