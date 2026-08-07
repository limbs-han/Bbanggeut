package com.wj.server.video.domain;

import java.time.LocalDate;

public record DailyVideoCountRow(LocalDate date, long count) {
}
