package com.wj.server.common.web;

import java.util.LinkedHashMap;
import java.util.Map;

import com.wj.server.common.api.ApiException;
import com.wj.server.common.api.ErrorResponse;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.bind.MissingRequestHeaderException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@RestControllerAdvice
public class GlobalExceptionHandler {
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<ErrorResponse> handleApi(ApiException exception, HttpServletRequest request) {
        return ResponseEntity.status(exception.status()).body(new ErrorResponse(
            exception.code(), exception.getMessage(), requestId(request), null));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ErrorResponse> handleValidation(
        MethodArgumentNotValidException exception,
        HttpServletRequest request
    ) {
        Map<String, String> fieldErrors = new LinkedHashMap<>();
        for (FieldError error : exception.getBindingResult().getFieldErrors()) {
            fieldErrors.putIfAbsent(error.getField(), error.getDefaultMessage());
        }
        return ResponseEntity.unprocessableEntity().body(new ErrorResponse(
            "VALIDATION_FAILED", "요청 값을 확인해 주세요.", requestId(request), fieldErrors));
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ErrorResponse> handleMalformedJson(
        HttpMessageNotReadableException exception,
        HttpServletRequest request
    ) {
        return ResponseEntity.unprocessableEntity().body(new ErrorResponse(
            "MALFORMED_JSON", "요청 본문 형식을 확인해 주세요.", requestId(request), null));
    }

    @ExceptionHandler(MissingRequestHeaderException.class)
    public ResponseEntity<ErrorResponse> handleMissingHeader(
        MissingRequestHeaderException exception,
        HttpServletRequest request
    ) {
        return ResponseEntity.unprocessableEntity().body(new ErrorResponse(
            "MISSING_REQUIRED_HEADER", "필수 요청 헤더를 확인해 주세요.", requestId(request), null));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleUnexpected(Exception exception, HttpServletRequest request) {
        log.error("Unhandled request error path={} requestId={}",
            request.getRequestURI(), requestId(request), exception);
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(new ErrorResponse(
            "INTERNAL_SERVER_ERROR", "서버 오류가 발생했습니다.", requestId(request), null));
    }

    private String requestId(HttpServletRequest request) {
        return String.valueOf(request.getAttribute(RequestIdFilter.ATTRIBUTE));
    }
}
