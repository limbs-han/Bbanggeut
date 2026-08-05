package com.wj.server.place.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.place.api.UpdateDeviceOrderRequest;
import com.wj.server.place.api.UpdatePlaceLayoutRequest;
import com.wj.server.place.persistence.PlaceMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class PlaceServiceTest {
    private static final UUID USER = UUID.randomUUID();
    private static final UUID VAULT = UUID.randomUUID();

    @Mock
    private PlaceMapper mapper;
    private PlaceService service;

    @BeforeEach
    void setUp() {
        service = new PlaceService(mapper);
        lenient().when(mapper.isActiveMember(USER, VAULT)).thenReturn(true);
        lenient().when(mapper.findPlaces(VAULT)).thenReturn(List.of());
        lenient().when(mapper.findDevicePlaces(VAULT)).thenReturn(List.of());
        lenient().when(mapper.findDeviceOrder(USER, VAULT)).thenReturn(List.of());
    }

    @Test
    void layoutOfAnotherFamilysVaultStaysHidden() {
        when(mapper.isActiveMember(USER, VAULT)).thenReturn(false);

        assertThatThrownBy(() -> service.get(USER, VAULT))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void placesKeepTheOrderTheyWereSentIn() {
        service.replaceLayout(USER, VAULT, new UpdatePlaceLayoutRequest(
            List.of("거실", "안방"), Map.of()));

        verify(mapper).insertPlace(VAULT, "거실", 0);
        verify(mapper).insertPlace(VAULT, "안방", 1);
    }

    @Test
    void placeNamesAreTrimmedAndDeduplicatedCaseInsensitively() {
        // "거실"과 "거실 "이 따로 생기면 기기 배정이 둘로 갈린다.
        service.replaceLayout(USER, VAULT, new UpdatePlaceLayoutRequest(
            List.of("  거실  ", "거실", "Living", "living", ""), Map.of()));

        verify(mapper).insertPlace(VAULT, "거실", 0);
        verify(mapper).insertPlace(VAULT, "Living", 1);
        verify(mapper, never()).insertPlace(eq(VAULT), eq(""), anyInt());
    }

    @Test
    void assignmentsToUnknownPlacesAreDropped() {
        // 앱이 목록을 통째로 보내므로 방금 지운 장소가 섞여 올 수 있다.
        UUID device = UUID.randomUUID();
        service.replaceLayout(USER, VAULT, new UpdatePlaceLayoutRequest(
            List.of("거실"), Map.of(device, "없는장소")));

        verify(mapper, never()).insertDevicePlace(any(), any(), anyString());
    }

    @Test
    void assignmentsToKnownPlacesAreKept() {
        UUID device = UUID.randomUUID();
        service.replaceLayout(USER, VAULT, new UpdatePlaceLayoutRequest(
            List.of("거실"), Map.of(device, "거실")));

        verify(mapper).insertDevicePlace(VAULT, device, "거실");
    }

    @Test
    void layoutWithoutAnyPlaceIsRejected() {
        assertThatThrownBy(() -> service.replaceLayout(USER, VAULT,
            new UpdatePlaceLayoutRequest(List.of("  "), Map.of())))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }

    @Test
    void tooLongPlaceNameIsRejected() {
        assertThatThrownBy(() -> service.replaceLayout(USER, VAULT,
            new UpdatePlaceLayoutRequest(List.of("가".repeat(16)), Map.of())))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "VALIDATION_FAILED");
    }

    @Test
    void deviceOrderIsPerUserAndDeduplicated() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();

        service.replaceDeviceOrder(USER, VAULT,
            new UpdateDeviceOrderRequest(List.of(first, second, first)));

        verify(mapper).deleteDeviceOrder(USER, VAULT);
        verify(mapper).insertDeviceOrder(USER, VAULT, first, 0);
        verify(mapper).insertDeviceOrder(USER, VAULT, second, 1);
        verify(mapper, never()).insertDeviceOrder(USER, VAULT, first, 2);
    }

    @Test
    void readingLayoutReturnsSharedPlacesAndOwnOrder() {
        UUID device = UUID.randomUUID();
        when(mapper.findPlaces(VAULT)).thenReturn(
            List.of(new com.wj.server.place.domain.PlaceRow("거실", 0)));
        when(mapper.findDevicePlaces(VAULT)).thenReturn(
            List.of(new com.wj.server.place.domain.DevicePlaceRow(device, "거실")));
        when(mapper.findDeviceOrder(USER, VAULT)).thenReturn(List.of(device));

        var layout = service.get(USER, VAULT);

        assertThat(layout.places()).containsExactly("거실");
        assertThat(layout.devicePlaces()).containsEntry(device, "거실");
        assertThat(layout.deviceOrder()).containsExactly(device);
    }
}
