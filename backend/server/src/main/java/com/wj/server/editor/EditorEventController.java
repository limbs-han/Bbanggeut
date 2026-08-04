package com.wj.server.editor;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/editor")
public class EditorEventController {
    private final EditorEventService service;

    public EditorEventController(EditorEventService service) {
        this.service = service;
    }

    @PostMapping("/events")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void handle(
        @RequestHeader(value = "Authorization", required = false) String authorization,
        @Valid @RequestBody EditorEventRequest request
    ) {
        service.handle(authorization, request);
    }
}
