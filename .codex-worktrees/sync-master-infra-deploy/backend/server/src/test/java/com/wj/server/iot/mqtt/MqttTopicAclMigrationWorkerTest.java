package com.wj.server.iot.mqtt;

import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.UUID;

import com.wj.server.provisioning.persistence.ProvisioningMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class MqttTopicAclMigrationWorkerTest {
    @Mock
    private ProvisioningMapper mapper;
    @Mock
    private DeviceMqttIdentityManager identityManager;

    @Test
    void migratesEachActiveOperatingIdentityOnlyOnce() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        when(mapper.findActiveOperatingDeviceIds()).thenReturn(List.of(
            first.toString(),
            second.toString()
        ));
        MqttTopicAclMigrationWorker worker =
            new MqttTopicAclMigrationWorker(mapper, identityManager);

        worker.migrate();
        worker.migrate();

        verify(identityManager).migrateTopicAcl(first);
        verify(identityManager).migrateTopicAcl(second);
        verify(mapper, times(1)).findActiveOperatingDeviceIds();
    }
}
