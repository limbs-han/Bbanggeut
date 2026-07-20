package com.wj.server.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.common.api.ErrorResponse;
import com.wj.server.common.web.RequestIdFilter;
import com.wj.server.iot.auth.DeviceAuthenticationFilter;
import com.wj.server.provisioning.api.ProvisioningAuthenticationFilter;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.security.web.authentication.AnonymousAuthenticationFilter;

@Configuration
@EnableConfigurationProperties({
    AuthProperties.class, DeviceClaimProperties.class, StorageProperties.class,
    InvitationProperties.class, MqttProperties.class, StreamProperties.class,
    SubscriptionProperties.class, ProvisioningProperties.class
})
public class SecurityConfig {

    @Bean
    @Order(1)
    public SecurityFilterChain provisioningFilterChain(
        HttpSecurity http,
        ProvisioningAuthenticationFilter provisioningAuthenticationFilter
    ) throws Exception {
        http
            .securityMatcher("/internal/admin/**")
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .addFilterBefore(provisioningAuthenticationFilter, AnonymousAuthenticationFilter.class)
            .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        return http.build();
    }

    @Bean
    @Order(2)
    public SecurityFilterChain deviceFilterChain(
        HttpSecurity http,
        ObjectMapper objectMapper,
        DeviceAuthenticationFilter deviceAuthenticationFilter
    ) throws Exception {
        http
            .securityMatcher("/api/iot/**")
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .addFilterBefore(deviceAuthenticationFilter, UsernamePasswordAuthenticationFilter.class)
            .authorizeHttpRequests(auth -> auth.anyRequest().authenticated())
            .exceptionHandling(errors -> errors.authenticationEntryPoint((request, response, exception) ->
                writeError(response, objectMapper, HttpServletResponse.SC_UNAUTHORIZED,
                    "DEVICE_AUTHENTICATION_FAILED", "기기 인증에 실패했습니다.",
                    request.getAttribute(RequestIdFilter.ATTRIBUTE))));
        return http.build();
    }

    @Bean
    @Order(3)
    public SecurityFilterChain userFilterChain(HttpSecurity http, ObjectMapper objectMapper) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/auth/signup", "/api/auth/login", "/api/auth/refresh").permitAll()
                .requestMatchers("/actuator/health").permitAll()
                .requestMatchers("/api/live/introspect").permitAll()
                .anyRequest().authenticated())
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> {})
                .authenticationEntryPoint((request, response, exception) -> writeError(
                    response, objectMapper, HttpServletResponse.SC_UNAUTHORIZED,
                    "AUTHENTICATION_REQUIRED", "로그인이 필요합니다.",
                    request.getAttribute(RequestIdFilter.ATTRIBUTE))))
            .exceptionHandling(errors -> errors
                .accessDeniedHandler((request, response, exception) -> writeError(
                    response, objectMapper, HttpServletResponse.SC_FORBIDDEN,
                    "ACCESS_DENIED", "접근 권한이 없습니다.",
                    request.getAttribute(RequestIdFilter.ATTRIBUTE))));
        return http.build();
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    private void writeError(
        HttpServletResponse response,
        ObjectMapper objectMapper,
        int status,
        String code,
        String message,
        Object requestId
    ) throws java.io.IOException {
        response.setStatus(status);
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        objectMapper.writeValue(response.getOutputStream(),
            new ErrorResponse(code, message, String.valueOf(requestId), null));
    }
}
