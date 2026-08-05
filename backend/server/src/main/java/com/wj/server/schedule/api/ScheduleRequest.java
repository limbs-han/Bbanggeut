package com.wj.server.schedule.api;

import java.time.LocalDate;
import java.util.UUID;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record ScheduleRequest(
    @NotBlank @Size(max = 80) String title,
    @NotNull LocalDate date,
    @Size(max = 500) String memo,
    Boolean yearly,
    @Size(max = 16) String emoji,
    /**
     * 일정을 넣을 금고. 생략하면 사용자가 속한 금고가 하나일 때만 그것으로
     * 정하고, 여러 곳에 속해 있으면 되묻는다.
     */
    UUID vaultId
) {
    public String memoOrEmpty() {
        return memo == null ? "" : memo;
    }

    public boolean yearlyOrFalse() {
        return Boolean.TRUE.equals(yearly);
    }

    public String emojiOrDefault() {
        return emoji == null || emoji.isBlank() ? "❤️" : emoji;
    }
}
