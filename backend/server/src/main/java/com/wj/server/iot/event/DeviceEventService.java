package com.wj.server.iot.event;

import java.time.Instant;
import java.util.UUID;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class DeviceEventService {
    private final DeviceEventMapper mapper;

    public DeviceEventService(DeviceEventMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional
    public void accept(DeviceEvent event) {
        if (mapper.insert(event) == 1 && "TOUCH".equals(event.type())) {
            mapper.enqueueOwnerTouchEmail(event.id());
        }
    }

    @Transactional
    public void linkUpload(
        UUID deviceId,
        UUID eventId,
        String eventType,
        Instant occurredAt,
        UUID videoId,
        String videoStatus
    ) {
        mapper.insertUploadRecovery(eventId, deviceId, eventType, occurredAt);
        mapper.linkVideo(deviceId, eventId, videoId, videoStatus);
    }
}
