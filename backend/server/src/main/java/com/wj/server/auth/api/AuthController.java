package com.wj.server.auth.api;

import java.util.UUID;

import com.wj.server.auth.application.AuthService;
import com.wj.server.auth.application.AuthService.ClientContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/auth")
public class AuthController {
    private final AuthService authService;

    public AuthController(AuthService authService) {
        this.authService = authService;
    }

    @PostMapping("/signup")
    public ResponseEntity<AuthTokenResponse> signUp(
        @Valid @RequestBody SignUpRequest request,
        @RequestHeader(value = "X-Client-Name", required = false) String clientName,
        HttpServletRequest servletRequest
    ) {
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(authService.signUp(request, context(clientName, servletRequest)));
    }

    @PostMapping("/login")
    public AuthTokenResponse login(
        @Valid @RequestBody LoginRequest request,
        @RequestHeader(value = "X-Client-Name", required = false) String clientName,
        HttpServletRequest servletRequest
    ) {
        return authService.login(request, context(clientName, servletRequest));
    }

    @PostMapping("/refresh")
    public AuthTokenResponse refresh(
        @Valid @RequestBody RefreshTokenRequest request,
        @RequestHeader(value = "X-Client-Name", required = false) String clientName,
        HttpServletRequest servletRequest
    ) {
        return authService.refresh(request, context(clientName, servletRequest));
    }

    @PostMapping("/logout")
    public ResponseEntity<Void> logout(@AuthenticationPrincipal Jwt jwt) {
        authService.logout(UUID.fromString(jwt.getSubject()), UUID.fromString(jwt.getClaimAsString("sid")));
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/me")
    public ResponseEntity<Void> withdraw(@AuthenticationPrincipal Jwt jwt) {
        authService.withdraw(UUID.fromString(jwt.getSubject()));
        return ResponseEntity.noContent().build();
    }

    private ClientContext context(String clientName, HttpServletRequest request) {
        return new ClientContext(clientName, request.getHeader("User-Agent"), request.getRemoteAddr());
    }
}
