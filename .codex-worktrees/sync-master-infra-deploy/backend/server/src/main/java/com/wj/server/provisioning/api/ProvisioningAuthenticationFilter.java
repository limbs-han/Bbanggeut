package com.wj.server.provisioning.api;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.common.api.ErrorResponse;
import com.wj.server.common.web.RequestIdFilter;
import com.wj.server.config.ProvisioningProperties;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class ProvisioningAuthenticationFilter extends OncePerRequestFilter {
    private final ProvisioningProperties properties;
    private final ObjectMapper objectMapper;

    public ProvisioningAuthenticationFilter(ProvisioningProperties properties, ObjectMapper objectMapper) {
        this.properties = properties;
        this.objectMapper = objectMapper;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !request.getRequestURI().startsWith("/internal/admin/");
    }

    @Override
    protected void doFilterInternal(
        HttpServletRequest request,
        HttpServletResponse response,
        FilterChain filterChain
    ) throws ServletException, IOException {
        String providedKey = request.getHeader("X-Provisioning-Key");
        if (!authorized(providedKey, request.getRemoteAddr())) {
            response.setStatus(HttpServletResponse.SC_NOT_FOUND);
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            objectMapper.writeValue(response.getOutputStream(), new ErrorResponse(
                "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.",
                String.valueOf(request.getAttribute(RequestIdFilter.ATTRIBUTE)), null));
            return;
        }
        filterChain.doFilter(request, response);
    }

    private boolean authorized(String providedKey, String remoteAddress) {
        return properties.enabled()
            && properties.adminKey() != null
            && properties.adminKey().length() >= 32
            && isLoopback(remoteAddress)
            && providedKey != null
            && MessageDigest.isEqual(
                providedKey.getBytes(StandardCharsets.UTF_8),
                properties.adminKey().getBytes(StandardCharsets.UTF_8));
    }

    private boolean isLoopback(String address) {
        return "127.0.0.1".equals(address) || "0:0:0:0:0:0:0:1".equals(address) || "::1".equals(address);
    }
}
