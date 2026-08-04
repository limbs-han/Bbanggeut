package com.wj.server.schedule.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.schedule.application.ScheduleService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/schedules")
public class ScheduleController {
    private final ScheduleService service;

    public ScheduleController(ScheduleService service) {
        this.service = service;
    }

    @GetMapping
    public List<ScheduleResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return service.list(userId(jwt));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public ScheduleResponse create(
        @AuthenticationPrincipal Jwt jwt,
        @Valid @RequestBody ScheduleRequest request
    ) {
        return service.create(userId(jwt), request);
    }

    @PutMapping("/{scheduleId}")
    public ScheduleResponse update(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID scheduleId,
        @Valid @RequestBody ScheduleRequest request
    ) {
        return service.update(userId(jwt), scheduleId, request);
    }

    @DeleteMapping("/{scheduleId}")
    public ResponseEntity<Void> delete(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID scheduleId
    ) {
        service.delete(userId(jwt), scheduleId);
        return ResponseEntity.noContent().build();
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
