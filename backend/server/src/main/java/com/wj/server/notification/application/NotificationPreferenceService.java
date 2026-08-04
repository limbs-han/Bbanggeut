package com.wj.server.notification.application;

import java.util.UUID;

import com.wj.server.notification.api.NotificationPreferencesResponse;
import com.wj.server.notification.api.UpdateNotificationPreferencesRequest;
import com.wj.server.notification.persistence.NotificationPreferenceMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class NotificationPreferenceService {
    /**
     * 행이 없는 사용자는 모두 켜진 것으로 본다. 설정이 단말 저장 전용이던
     * 시절의 사용자가 서버 전환만으로 푸시를 잃지 않게 하기 위한 기본값이다.
     */
    static final NotificationPreferencesResponse DEFAULTS =
        new NotificationPreferencesResponse(true, true, true);

    private final NotificationPreferenceMapper mapper;

    public NotificationPreferenceService(NotificationPreferenceMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional(readOnly = true)
    public NotificationPreferencesResponse get(UUID userId) {
        return mapper.findForUser(userId)
            .map(row -> new NotificationPreferencesResponse(
                row.anniversaryAlerts(), row.weeklyReport(), row.newMemoryAlerts()))
            .orElse(DEFAULTS);
    }

    @Transactional
    public NotificationPreferencesResponse update(
        UUID userId, UpdateNotificationPreferencesRequest request
    ) {
        mapper.upsert(
            userId, request.anniversaryAlerts(), request.weeklyReport(),
            request.newMemoryAlerts());
        return new NotificationPreferencesResponse(
            request.anniversaryAlerts(), request.weeklyReport(), request.newMemoryAlerts());
    }
}
