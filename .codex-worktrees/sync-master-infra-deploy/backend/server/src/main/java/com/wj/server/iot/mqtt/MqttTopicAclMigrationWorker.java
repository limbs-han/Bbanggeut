package com.wj.server.iot.mqtt;

import java.util.UUID;

import com.wj.server.provisioning.persistence.ProvisioningMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Migrates identities stored in Mosquitto's persistent Dynamic Security volume.
 * New identities already use v2; this worker repairs identities created before
 * the topic namespace upgrade.
 */
@Component
public class MqttTopicAclMigrationWorker {
    private static final Logger log = LoggerFactory.getLogger(MqttTopicAclMigrationWorker.class);

    private final ProvisioningMapper mapper;
    private final DeviceMqttIdentityManager identityManager;
    private volatile boolean completed;

    public MqttTopicAclMigrationWorker(
        ProvisioningMapper mapper,
        DeviceMqttIdentityManager identityManager
    ) {
        this.mapper = mapper;
        this.identityManager = identityManager;
    }

    @Scheduled(initialDelay = 10_000, fixedDelay = 30_000)
    public void migrate() {
        if (completed) {
            return;
        }
        int migrated = 0;
        try {
            for (String deviceId : mapper.findActiveOperatingDeviceIds()) {
                identityManager.migrateTopicAcl(UUID.fromString(deviceId));
                migrated++;
            }
            completed = true;
            log.info("MQTT topic ACL migration to wj/v2 completed for {} devices", migrated);
        } catch (RuntimeException exception) {
            log.warn("MQTT topic ACL migration deferred", exception);
        }
    }
}
