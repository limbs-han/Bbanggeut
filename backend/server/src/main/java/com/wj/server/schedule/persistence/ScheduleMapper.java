package com.wj.server.schedule.persistence;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import com.wj.server.schedule.domain.ScheduleRow;
import org.apache.ibatis.annotations.Delete;
import org.apache.ibatis.annotations.Insert;
import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;
import org.apache.ibatis.annotations.Update;

@Mapper
public interface ScheduleMapper {
    @Select("""
        SELECT id, user_id AS userId, title, schedule_date AS scheduleDate,
               memo, yearly, emoji
          FROM user_schedules
         WHERE user_id = #{userId}
         ORDER BY schedule_date, created_at, id
        """)
    List<ScheduleRow> findForUser(@Param("userId") UUID userId);

    @Select("""
        SELECT count(*) FROM user_schedules WHERE user_id = #{userId}
        """)
    long countForUser(@Param("userId") UUID userId);

    @Insert("""
        INSERT INTO user_schedules (id, user_id, title, schedule_date, memo, yearly, emoji)
        VALUES (#{id}, #{userId}, #{title}, #{scheduleDate}, #{memo}, #{yearly}, #{emoji})
        """)
    int insert(
        @Param("id") UUID id,
        @Param("userId") UUID userId,
        @Param("title") String title,
        @Param("scheduleDate") LocalDate scheduleDate,
        @Param("memo") String memo,
        @Param("yearly") boolean yearly,
        @Param("emoji") String emoji
    );

    @Update("""
        UPDATE user_schedules
           SET title = #{title},
               schedule_date = #{scheduleDate},
               memo = #{memo},
               yearly = #{yearly},
               emoji = #{emoji},
               updated_at = now()
         WHERE id = #{id} AND user_id = #{userId}
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

    @Delete("""
        DELETE FROM user_schedules WHERE id = #{id} AND user_id = #{userId}
        """)
    int delete(@Param("id") UUID id, @Param("userId") UUID userId);
}
