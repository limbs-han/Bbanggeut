package com.wj.server.config;

import java.util.UUID;

import org.mybatis.spring.boot.autoconfigure.ConfigurationCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class MyBatisConfig {
    /** Registered explicitly so a mapper can return a bare uuid scalar. */
    @Bean
    public ConfigurationCustomizer uuidTypeHandlerCustomizer() {
        return configuration ->
            configuration.getTypeHandlerRegistry().register(UUID.class, new UuidTypeHandler());
    }
}
