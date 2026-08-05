package com.wj.server.place.api;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import jakarta.validation.constraints.NotNull;

/**
 * 금고 공통 배치를 통째로 갈아 끼운다.
 *
 * <p>앱이 한 화면에서 장소 추가와 기기 이동을 함께 하므로 항목별 API로 나누면
 * 중간 상태가 서버에 남는다.
 */
public record UpdatePlaceLayoutRequest(
    @NotNull List<String> places,
    @NotNull Map<UUID, String> devicePlaces
) {
}
