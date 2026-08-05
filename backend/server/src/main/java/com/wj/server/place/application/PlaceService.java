package com.wj.server.place.application;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.place.api.PlaceLayoutResponse;
import com.wj.server.place.api.UpdateDeviceOrderRequest;
import com.wj.server.place.api.UpdatePlaceLayoutRequest;
import com.wj.server.place.domain.DevicePlaceRow;
import com.wj.server.place.domain.PlaceRow;
import com.wj.server.place.persistence.PlaceMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 장소 배치(금고 공통)와 기기 순서(사람마다).
 *
 * <p>장소 이름과 기기가 어느 장소에 있는지는 집의 사실이라 가족이 함께 본다.
 * 기기를 어떤 순서로 볼지는 보기 취향이라 사람마다 둔다. 어느 장소를 지금 보고
 * 있는지는 화면 상태라 서버에 두지 않는다.
 */
@Service
public class PlaceService {
    /** 장소 이름 길이. 앱 입력 제한과 같은 값이다. */
    static final int MAX_PLACE_NAME_LENGTH = 15;

    /** 한 금고의 장소 수 상한. 폭주만 막는다. */
    static final int MAX_PLACES = 20;

    private final PlaceMapper mapper;

    public PlaceService(PlaceMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(readOnly = true)
    public PlaceLayoutResponse get(UUID userId, UUID vaultId) {
        requireMember(userId, vaultId);
        return read(userId, vaultId);
    }

    /**
     * 금고 공통 배치를 바꾼다. 구성원 누구나 할 수 있다.
     *
     * <p>OWNER로 좁히지 않은 이유는 장소가 집의 사실이라는 데 있다 — 홈캠을
     * 안방으로 옮긴 사람이 그 사실을 적을 수 있어야 하고, 잘못 적어도 되돌리기
     * 쉬운 데이터다.
     */
    @Transactional
    public PlaceLayoutResponse replaceLayout(
        UUID userId, UUID vaultId, UpdatePlaceLayoutRequest request
    ) {
        requireMember(userId, vaultId);
        List<String> places = normalizePlaces(request.places());
        if (places.isEmpty()) {
            throw validation("장소는 하나 이상 있어야 합니다.");
        }
        if (places.size() > MAX_PLACES) {
            throw validation("장소는 최대 " + MAX_PLACES + "개까지 만들 수 있습니다.");
        }

        mapper.deletePlaces(vaultId);
        for (int index = 0; index < places.size(); index++) {
            mapper.insertPlace(vaultId, places.get(index), index);
        }

        mapper.deleteDevicePlaces(vaultId);
        for (Map.Entry<UUID, String> entry : request.devicePlaces().entrySet()) {
            String place = entry.getValue() == null ? "" : entry.getValue().strip();
            // 없는 장소로 보낸 배정은 버린다. 앱이 목록을 통째로 보내므로 방금
            // 지운 장소가 섞여 올 수 있고, 그것 때문에 저장 전체를 실패시키면
            // 사용자는 왜 안 되는지 알 수 없다.
            if (!places.contains(place)) {
                continue;
            }
            mapper.insertDevicePlace(vaultId, entry.getKey(), place);
        }
        return read(userId, vaultId);
    }

    /** 부른 사람의 기기 순서만 바꾼다. 다른 구성원 화면에는 영향이 없다. */
    @Transactional
    public PlaceLayoutResponse replaceDeviceOrder(
        UUID userId, UUID vaultId, UpdateDeviceOrderRequest request
    ) {
        requireMember(userId, vaultId);
        mapper.deleteDeviceOrder(userId, vaultId);
        List<UUID> deviceIds = new ArrayList<>(new LinkedHashSet<>(request.deviceIds()));
        for (int index = 0; index < deviceIds.size(); index++) {
            mapper.insertDeviceOrder(userId, vaultId, deviceIds.get(index), index);
        }
        return read(userId, vaultId);
    }

    private PlaceLayoutResponse read(UUID userId, UUID vaultId) {
        List<String> places = mapper.findPlaces(vaultId).stream()
            .map(PlaceRow::name)
            .toList();
        Map<UUID, String> devicePlaces = new LinkedHashMap<>();
        for (DevicePlaceRow row : mapper.findDevicePlaces(vaultId)) {
            devicePlaces.put(row.deviceId(), row.placeName());
        }
        return new PlaceLayoutResponse(
            places, devicePlaces, mapper.findDeviceOrder(userId, vaultId));
    }

    /**
     * 이름을 다듬고 중복을 없앤다.
     *
     * <p>대소문자만 다른 이름은 같은 장소로 본다 — 앱이 이미 그렇게 막고 있고,
     * "거실"과 "거실 "이 따로 생기면 기기 배정이 둘로 갈린다.
     */
    private List<String> normalizePlaces(List<String> requested) {
        Map<String, String> byLowerCase = new LinkedHashMap<>();
        for (String candidate : requested) {
            String name = candidate == null ? "" : candidate.strip();
            if (name.isEmpty()) {
                continue;
            }
            if (name.length() > MAX_PLACE_NAME_LENGTH) {
                throw validation(
                    "장소 이름은 " + MAX_PLACE_NAME_LENGTH + "자 이하여야 합니다.");
            }
            byLowerCase.putIfAbsent(name.toLowerCase(), name);
        }
        return List.copyOf(byLowerCase.values());
    }

    private void requireMember(UUID userId, UUID vaultId) {
        if (!mapper.isActiveMember(userId, vaultId)) {
            throw new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
        }
    }

    private ApiException validation(String message) {
        return new ApiException(
            HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
