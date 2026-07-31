package com.wj.server.config;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.apache.ibatis.session.Configuration;
import org.junit.jupiter.api.Test;

class MyBatisConfigTest {
    @Test
    void registersUuidTypeHandlerSoMappersCanReturnBareUuidScalars() {
        var configuration = new Configuration();

        assertThat(configuration.getTypeHandlerRegistry().hasTypeHandler(UUID.class)).isFalse();

        new MyBatisConfig().uuidTypeHandlerCustomizer().customize(configuration);

        assertThat(configuration.getTypeHandlerRegistry().hasTypeHandler(UUID.class)).isTrue();
        assertThat(configuration.getTypeHandlerRegistry().getTypeHandler(UUID.class))
            .isInstanceOf(UuidTypeHandler.class);
    }
}
