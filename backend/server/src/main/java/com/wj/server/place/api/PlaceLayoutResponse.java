package com.wj.server.place.api;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 금고의 장소 배치와, 요청한 사람의 기기 순서.
 *
 * <p>{@code places}와 {@code devicePlaces}는 금고 공통이고 {@code deviceOrder}는
 * 부른 사람의 것이다 — 장소는 집의 사실이고 순서는 보기 취향이라 성질이 다르다.
 */
public record PlaceLayoutResponse(
    List<String> places,
    Map<UUID, String> devicePlaces,
    List<UUID> deviceOrder
) {
}
