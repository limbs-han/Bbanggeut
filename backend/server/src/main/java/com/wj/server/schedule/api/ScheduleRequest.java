package com.wj.server.schedule.api;

import java.time.LocalDate;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record ScheduleRequest(
    @NotBlank @Size(max = 80) String title,
    @NotNull LocalDate date,
    @Size(max = 500) String memo,
    Boolean yearly,
    @Size(max = 16) String emoji
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
