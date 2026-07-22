package com.wj.server.iot.auth;

import java.io.IOException;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
public class DeviceAuthenticationFilter extends OncePerRequestFilter {
    private final DeviceCredentialAuthenticator authenticator;

    public DeviceAuthenticationFilter(DeviceCredentialAuthenticator authenticator) {
        this.authenticator = authenticator;
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        return !request.getServletPath().startsWith("/api/iot/");
    }

    @Override
    protected void doFilterInternal(
        HttpServletRequest request,
        HttpServletResponse response,
        FilterChain filterChain
    ) throws ServletException, IOException {
        String authorization = request.getHeader("Authorization");
        if (authorization != null && authorization.startsWith("Bearer ")) {
            authenticator.authenticate(authorization.substring(7))
                .ifPresent(principal -> SecurityContextHolder.getContext().setAuthentication(
                    UsernamePasswordAuthenticationToken.authenticated(
                        principal,
                        null,
                        java.util.List.of(new SimpleGrantedAuthority("ROLE_DEVICE_" + principal.purpose())))));
        }
        filterChain.doFilter(request, response);
    }
}
