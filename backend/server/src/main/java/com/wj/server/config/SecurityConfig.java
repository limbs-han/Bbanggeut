package com.wj.server.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.common.api.ErrorResponse;
import com.wj.server.common.web.RequestIdFilter;
import com.wj.server.iot.auth.DeviceAuthenticationFilter;
import com.wj.server.provisioning.api.ProvisioningAuthenticationFilter;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.MediaType;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;
import org.springframework.security.web.authentication.AnonymousAuthenticationFilter;

@Configuration
@EnableConfigurationProperties({
    AuthProperties.class, DeviceClaimProperties.class, StorageProperties.class,
    InvitationProperties.class, MqttProperties.class, StreamProperties.class,
    SubscriptionProperties.class, ProvisioningProperties.class, DeviceCredentialProperties.class,
    PushProperties.class, DevicePresenceProperties.class,
    ComicProperties.class, MediaMtxProperties.class
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
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/api/iot/enrollment").hasRole("DEVICE_BOOTSTRAP")
                .anyRequest().hasRole("DEVICE_OPERATING"))
            .exceptionHandling(errors -> errors.authenticationEntryPoint((request, response, exception) ->
                writeError(response, objectMapper, HttpServletResponse.SC_UNAUTHORIZED,
                    "DEVICE_AUTHENTICATION_FAILED", "기기 인증에 실패했습니다.",
                    request.getAttribute(RequestIdFilter.ATTRIBUTE))));
        return http.build();
    }

    /**
     * 편집 서버(editor-api)의 서비스 이벤트 전용 체인.
     *
     * <p>토큰이 사용자 세션이 아니라 {@code iss=wj-editor} 서비스 토큰이라
     * 사용자 체인의 액세스 토큰 디코더로는 검증할 수 없다. 그런데 사용자
     * 체인에 {@code permitAll}만 걸어 두는 것으로는 부족했다 —
     * {@code permitAll}은 <b>인가</b> 규칙이고, Bearer 헤더가 실려 오면 그
     * 앞의 <b>인증</b> 필터가 먼저 액세스 토큰으로 검증을 시도해 실패하고
     * 컨트롤러 도달 전에 401을 낸다. 실제로 운영에서 편집 분석 완료 알림이
     * 이 401 때문에 한 건도 발송되지 않았다.
     *
     * <p>그래서 체인을 분리해 인증 필터를 아예 태우지 않고, 토큰 검증은
     * {@link com.wj.server.editor.EditorEventService}가 직접 한다.
     * 라이브 introspect는 토큰을 쿼리 파라미터로 받아 같은 문제가 없다.
     */
    @Bean
    @Order(3)
    public SecurityFilterChain editorEventFilterChain(HttpSecurity http) throws Exception {
        http
            .securityMatcher("/api/editor/**")
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth.anyRequest().permitAll());
        return http.build();
    }

    @Bean
    @Order(4)
    public SecurityFilterChain userFilterChain(
        HttpSecurity http,
        ObjectMapper objectMapper,
        @Qualifier("accessTokenJwtDecoder") JwtDecoder accessTokenJwtDecoder
    ) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                .requestMatchers(
                    "/api/auth/signup", "/api/auth/login", "/api/auth/refresh",
                    "/api/auth/password/forgot", "/api/auth/password/reset").permitAll()
                .requestMatchers(
                    HttpMethod.GET, "/api/membership-request-links/*/open").permitAll()
                .requestMatchers("/actuator/health").permitAll()
                // Prometheus 수집용. 8081은 loopback 전용이고 nginx는 이 경로를
                // 프록시하지 않는다 — 8081 공개로 바꾸면 함께 재검토할 것.
                .requestMatchers("/actuator/prometheus").permitAll()
                .requestMatchers("/api/live/introspect").permitAll()
                // /api/editor/** 는 editorEventFilterChain이 먼저 잡는다.
                // 여기에 permitAll을 두면 안 된다 — 이 체인에 들어오는 순간
                // 인증 필터가 Bearer 헤더를 액세스 토큰으로 검증해 401이 된다.
                .anyRequest().authenticated())
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt.decoder(accessTokenJwtDecoder))
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
